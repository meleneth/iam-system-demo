# frozen_string_literal: true
require "json"
require "net/http"
require "digest"
require "time"
require_relative "benchmark_environment"

# Expected scopes come from the seed manifest, never from /can or a privileged
# enumeration response. This gate runs against the actual stack being measured.
class AuthorizationCorrectnessGate
  def initialize(settings: BenchmarkEnvironment.values)
    @settings = settings
    @manifest = JSON.parse(File.read(settings.fetch("MANIFEST")))
    @checks = []
    @errors = []
  end

  def request(service, path, actor:, body: nil)
    uri = URI(@settings.fetch("#{service}_BASE_URL") + path)
    req = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req["pad-user-id"] = actor
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body) if body
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) { |http| http.request(req) }
  end

  def check(label)
    yield
    @checks << {name: label, passed: true}
  rescue StandardError => error
    @checks << {name: label, passed: false, error: error.message}
    @errors << label
  end

  def exact!(actual, expected)
    raise "Expected #{expected.inspect}, received #{actual.inspect}" unless actual == expected
  end

  def run(output:)
    fixtures = @manifest.fetch("fixtures")
    msps = fixtures.select { |f| f["msp"] }
    raise "At least two independent MSP fixtures required for correctness gate" unless msps.size >= 2
    # Every seeded benchmark admin must fail against another fixture's root.
    # MSP-owned clients are tested separately as legitimate related targets.
    fixtures.each_with_index do |fixture, index|
      actor = fixture.fetch("targets").fetch("top_level_admin_user_id")
      own = fixture.fetch("targets").fetch("top_level_account_id")
      other = fixtures.fetch((index + 1) % fixtures.size).fetch("targets").fetch("top_level_account_id")
      2.times do |pass|
        check("#{fixture.fetch('name')} account identities pass #{pass}") do
          allowed = request("ACCOUNT_SERVICE", "/accounts/#{own}", actor: actor)
          exact!(allowed.code, "200")
          exact!(JSON.parse(allowed.body).fetch("id"), own)
          denied = request("ACCOUNT_SERVICE", "/accounts/#{other}", actor: actor)
          exact!(denied.code, "403")
        end
      end
    end
    msps.each_with_index do |fixture, index|
      other = msps.fetch((index + 1) % msps.size)
      actor = fixture.fetch("targets").fetch("top_level_admin_user_id")
      own_org = fixture.fetch("organization_id")
      other_org = other.fetch("organization_id")
      own_account = fixture.fetch("targets").fetch("msp_account_id")
      check("#{fixture.fetch('name')} mixed Organization list denial") do
        allowed = request("ORGANIZATION_SERVICE", "/organization_accounts?organization_id=#{own_org}", actor: actor)
        exact!(allowed.code, "200")
        expected_accounts = fixture.fetch("targets").fetch("organization_account_ids", [own_account])
        exact!(JSON.parse(allowed.body).map { |r| r.fetch("account_id") }.sort, expected_accounts.sort)
        denied = request("ORGANIZATION_SERVICE", "/organization_accounts?organization_id[]=#{own_org}&organization_id[]=#{other_org}", actor: actor)
        exact!(denied.code, "403")
      end
      client = fixture.fetch("targets").fetch("sample_account_ids").first
      other_client = other.fetch("targets").fetch("sample_account_ids").first
      2.times do |pass|
        check("#{fixture.fetch('name')} owned client allow / unrelated MSP denial pass #{pass}") do
          allowed = request("ACCOUNT_SERVICE", "/accounts/#{client}", actor: actor)
          exact!(allowed.code, "200")
          exact!(JSON.parse(allowed.body).fetch("id"), client)
          exact!(request("ACCOUNT_SERVICE", "/accounts/#{other_client}", actor: actor).code, "403")
          mixed = request("ACCOUNT_SERVICE", "/accounts/search", actor: actor, body: {id: [client, other_client]})
          exact!(mixed.code, "403")
        end
      end
    end
    branching = fixtures.find { |fixture| fixture["name"] == "branching_tree" }
    if branching
      check("branching fixture's last leaf is outside the first root admin's authority") do
        actor = branching.fetch("targets").fetch("top_level_admin_user_id")
        leaf = branching.fetch("targets").fetch("leaf_account_id")
        exact!(request("ACCOUNT_SERVICE", "/accounts/#{leaf}", actor: actor).code, "403")
      end
    end
    result = {passed: @errors.empty?, checked_at: Time.now.utc.iso8601,
      manifest_sha256: Digest::SHA256.file(@settings.fetch("MANIFEST")).hexdigest,
      stack: @settings.fetch("BENCHMARK_STACK"), checks: @checks,
      limitation: "Sampled seed identities and boundaries; full measured response identity validation and the cross-service regression matrix remain required."}
    File.write(output, JSON.pretty_generate(result) + "\n", mode: "wx")
    raise "Authorization correctness gate failed: #{@errors.join(', ')}; see #{output}" unless @errors.empty?
    result
  end
end

if $PROGRAM_NAME == __FILE__
  AuthorizationCorrectnessGate.new.run(output: ARGV.fetch(0))
end
