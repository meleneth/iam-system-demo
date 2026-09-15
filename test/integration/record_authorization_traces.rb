# Small explanatory traces against the same isolated persisted proof fixture.
# Expected decisions are stated explicitly, independently of /can/capabilities.
require 'json'
require 'net/http'
require 'securerandom'
require 'redis'
require_relative 'record_authorization_fixture'
require_relative '../../scripts/workload_trace'
F = RecordAuthorizationFixture
mode = ENV.fetch('AUTHORIZATION_CHECK_MODE')
raise 'Redis must be enabled for cold/warm trace inspection' unless ENV['GLOBAL_IAM_DEMO_USE_REDIS'] == 'true'
id = ->(key) { F.id(key) }
cases = []
[
  ['Account', 'account-service', 'accounts', '', 'read_child'],
  ['User', 'user-service', 'users', 'user_', 'users_child'],
  ['Group', 'group-service', 'groups', 'group_', 'users_child'],
  ['Membership', 'group-service', 'group_users', 'membership_', 'users_child'],
  ['Organization relationship', 'organization-service', 'organization_accounts', 'link_', 'read_child']
].each do |record, service, resource, prefix, actor|
  %i[child sibling].each do |target|
    cases << [record, service, "/#{resource}/#{id.call("#{prefix}#{target}")}", actor, nil, target == :child, target]
  end
end
%w[users groups].each do |resource|
  %i[child sibling].each do |target|
    cases << ["#{resource.capitalize} count", resource == 'users' ? 'user-service' : 'group-service',
              "/accounts/#{resource}/counts", 'users_child', {account_id: [id.call(target)]}, target == :child, target]
  end
end
%i[client other_client].each do |target|
  cases << ['Organization', 'organization-service', "/organizations/#{id.call(target)}", 'org_client', nil, target == :client, target]
  cases << ['Organization account count', 'organization-service', "/organizations/accounts/counts/#{id.call(target)}", 'list_client', nil, target == :client, target]
end
%w[read_root read_child].each do |actor|
  cases << ['Hierarchy', 'account-service', '/accounts_with_parents', actor, {account_ids: [id.call(:leaf)]}, actor == 'read_root', :leaf]
end
%w[full read_provider_root].each do |actor|
  cases << ['Organization account IDs', 'organization-service', '/organization_account_ids/for_account_ids', actor, {account_ids: [id.call(:child)]}, actor == 'full', :child]
  cases << ['Organization context', 'organization-service', "/organization_account_ids/for_account_id/#{id.call(:child)}", actor, nil, actor == 'full', :child]
end
%w[read_provider_root read_foreign_provider].each do |actor|
  cases << ['MSP page', 'organization-service', "/msp_managed_organizations/#{id.call(:provider)}?limit=2", actor, nil, actor == 'read_provider_root', :provider]
end
records = []
cases.each do |record, service, path, actor, body, allowed, target|
  (1..4).each do |db|
    cache = Redis.new(url: "redis://authcache:6379/#{db}")
    cache.scan_each(match: '*a1710000*').each { |key| cache.del(key) }
  end
  %w[cold warm].each do |phase|
    trace_id, span_id = SecureRandom.hex(16), SecureRandom.hex(8)
    name = "#{allowed ? 'Allow' : 'Deny'} #{record} | actor #{actor} | target #{target} | #{mode} | Redis #{phase}"
    attributes = {
      'workload.intent' => "Prove #{record} #{allowed ? 'allow' : 'deny'}", 'fixture.profile' => 'record-authorization-proof',
      'authorization.mode' => mode, 'authorization.expected' => allowed ? 'allow' : 'deny',
      'authorization.actor_fixture' => actor, 'authorization.target_fixture' => target.to_s,
      'fixture.actor.id' => id.call("actor_#{actor}"), 'fixture.target.id' => id.call(target),
      'authorization.record_type' => record, 'url.full' => "http://#{service}:80#{path}",
      'redis.enabled' => true, 'redis.phase' => phase,
      'workload.revision' => ENV.fetch('PROOF_SOURCE_REVISION', 'unknown')
    }
    trace = WorkloadTrace.new(endpoint: 'http://otel-collector:4318', name: name, attributes: attributes)
    uri = URI("http://#{service}:80#{path}")
    req = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req['pad-user-id'] = id.call("actor_#{actor}")
    req['Content-Type'] = 'application/json'
    req['traceparent'] = "00-#{trace_id}-#{span_id}-01"
    req.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(req) }
    trace.stop
    attributes['http.response.status_code'] = response.code.to_i
    attributes['authorization.observed'] = response.code == '200' ? 'allow' : response.code == '403' ? 'deny' : 'error'
    expected = allowed ? '200' : '403'
    trace.export(trace_id: trace_id, span_id: span_id, outcome: response.code == expected ? 'ok' : 'unexpected_authorization_result')
    raise "#{name}: expected #{expected}, received #{response.code}" unless response.code == expected
    records << {name: name, trace_id: trace_id, parent_id: span_id, service: service, status: response.code,
                expected: allowed ? 'allow' : 'deny', url: "http://localhost:11030/trace/#{trace_id}"}
  end
end
# Archive only after both the real initiating span and the downstream server
# span have been exported. Polling/export time is outside the workload duration.
records.each do |record|
  30.times do |attempt|
    response = Net::HTTP.get_response(URI("http://jaeger:16686/api/traces/#{record.fetch(:trace_id)}"))
    payload = JSON.parse(response.body) rescue {}
    trace = Array(payload['data']).first
    spans = trace && trace['spans']
    ids = Array(spans).map { |s| s['spanID'] }
    has_auth = trace && trace.fetch('processes').values.any? { |p| p['serviceName'] == 'authorization-service' }
    complete_parents = spans && spans.all? { |s| s['references'].all? { |r| ids.include?(r['spanID']) } }
    has_server = spans && spans.any? { |s| s['references'].any? { |r| r['spanID'] == record.fetch(:parent_id) } && s['tags'].any? { |t| t['key'] == 'span.kind' && t['value'] == 'server' } }
    if ids.include?(record.fetch(:parent_id)) && has_auth && complete_parents && has_server
      File.write("/evidence/#{record.fetch(:trace_id)}.json", JSON.pretty_generate(payload) + "\n")
      record[:spans] = spans.size
      break
    end
    raise "Incomplete trace #{record.fetch(:trace_id)}" if attempt == 29
    sleep 1
  end
end
File.write('/evidence/trace-index.json', JSON.pretty_generate(records) + "\n")
puts "Verified and archived #{records.size} authorization traces for #{mode}"
