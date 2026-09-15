require 'rspec/core'
require 'net/http'
require 'json'
require 'redis'
require_relative 'record_authorization_fixture'

RSpec.describe 'Every checked record type: independent authorization oracle' do
  F = RecordAuthorizationFixture
  # Hand-written expected reachability, NOT derived from PARENTS or production code.
  COVERAGE = {
    root: %i[root child leaf sibling], child: %i[child leaf], leaf: [:leaf], sibling: [:sibling],
    detached: [:detached], foreign: [:foreign], second_client: [:second_client],
    provider_root: %i[provider_root provider root child leaf sibling detached second_client],
    provider: %i[provider root child leaf sibling detached second_client], foreign_provider: %i[foreign_provider foreign]
  }.freeze
  TARGETS = %i[root child leaf sibling detached foreign second_client].freeze
  RECORDS = {
    account: ['account-service', 'accounts', '', :read],
    user: ['user-service', 'users', 'user_', :users],
    group: ['group-service', 'groups', 'group_', :users],
    membership: ['group-service', 'group_users', 'membership_', :users],
    organization_relationship: ['organization-service', 'organization_accounts', 'link_', :read]
  }.freeze

  def id(key) = F.id(key)
  def call(service, path, actor:, body: nil, headers: {})
    uri = URI("http://#{service}:80#{path}")
    req = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req['pad-user-id'] = id("actor_#{actor}") if actor
    headers.each { |k, v| req[k] = v }
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(req) }
    if ENV['PROOF_LEDGER']
      File.open(ENV.fetch('PROOF_LEDGER'), 'a') do |file|
        file.puts JSON.generate(example: RSpec.current_example.full_description, phase: @proof_phase,
          mode: ENV.fetch('AUTHORIZATION_CHECK_MODE'), redis: ENV.fetch('GLOBAL_IAM_DEMO_USE_REDIS'),
          service: service, path: path, actor: actor, request: body, status: response.code,
          response: (JSON.parse(response.body) rescue response.body.to_s[0, 300]))
      end
    end
    response
  end
  def json(response) = JSON.parse(response.body)
  def check(response, allowed, ids: nil, count: nil)
    expect(response.code).to eq(allowed ? '200' : '403'), "#{RSpec.current_example.full_description}: #{response.code} #{response.body.to_s[0, 250]}"
    return unless allowed
    if ids
      rows = json(response)
      rows = [rows] unless rows.is_a?(Array)
      expect(rows.flatten.map { |row| row.fetch('id') }).to match_array(ids)
    end
    expect(json(response)).to eq(count) if count
  end
  def phases
    # First invocation starts with empty fixture caches; the second repeats the
    # same actor/target decisions without clearing them, including denied entries.
    2.times { |pass| @proof_phase = pass.zero? ? 'cold' : 'warm'; yield }
  end
  before do
    if ENV.fetch('GLOBAL_IAM_DEMO_USE_REDIS', 'false') == 'true'
      (1..4).each do |db|
        cache = Redis.new(url: "redis://authcache:6379/#{db}")
        cache.scan_each(match: '*a1710000*').each { |key| cache.del(key) }
      end
    end
  end

  RECORDS.each do |record, (service, resource, prefix, permission)|
    COVERAGE.each do |scope, allowed_targets|
      it "#{record} respects #{permission} grant at #{scope} for individual, filtered, and mixed reads" do
        actor = "#{permission}_#{scope}"
        phases do
          TARGETS.each do |target|
            target_id = id("#{prefix}#{target}")
            allowed = allowed_targets.include?(target)
            check(call(service, "/#{resource}/#{target_id}", actor: actor), allowed, ids: [target_id])
            check(call(service, "/#{resource}?#{record == :organization_relationship ? 'account_id' : 'id'}[]=#{record == :organization_relationship ? id(target) : target_id}", actor: actor), allowed, ids: [target_id])
            unless record == :organization_relationship
              check(call(service, "/#{resource}/search", actor: actor, body: {id: [target_id]}), allowed, ids: [target_id])
            end
          end
          yes = (allowed_targets & TARGETS).first
          no = (TARGETS - allowed_targets).first
          next unless yes && no
          [[yes, no], [no, yes]].each do |targets|
            ids = targets.map { |t| id("#{prefix}#{t}") }
            if record == :organization_relationship
              check(call(service, "/#{resource}?#{URI.encode_www_form(targets.map { |v| ['account_id[]', id(v)] })}", actor: actor), false)
            else
              check(call(service, "/#{resource}/search", actor: actor, body: {id: ids}), false)
            end
          end
        end
      end
    end
    it "#{record} rejects wrong permission, wrong scope, nonmember, and missing actor after an allowed read" do
      target = id("#{prefix}child")
      wrong = permission == :read ? 'users_child' : 'read_child'
      phases do
        check(call(service, "/#{resource}/#{target}", actor: "#{permission}_child"), true, ids: [target])
        [wrong, "#{permission}_wrong_scope", 'nonmember', nil].each do |actor|
          check(call(service, "/#{resource}/#{target}", actor: actor), false)
        end
      end
    end
  end

  %w[users groups].each do |resource|
    it "#{resource} counts authorize each requested account including zero counts and mixed batches" do
      service = resource == 'users' ? 'user-service' : 'group-service'
      phases do
        COVERAGE.each do |scope, allowed_targets|
          TARGETS.each do |target|
            expected = {id(target) => (resource == 'groups' && target == :child ? 2 : 1)}
            check(call(service, "/accounts/#{resource}/counts", actor: "users_#{scope}", body: {account_id: [id(target)]}), allowed_targets.include?(target), count: expected)
            check(call(service, "/accounts/#{resource}/counts?account_id[]=#{id(target)}", actor: "users_#{scope}"), allowed_targets.include?(target), count: expected)
          end
        end
        [[id(:child), id(:foreign)], [id(:foreign), id(:child)]].each do |ids|
          check(call(service, "/accounts/#{resource}/counts", actor: 'users_child', body: {account_id: ids}), false)
        end
        %w[read_child users_wrong_scope nonmember exact_child].each { |actor| check(call(service, "/accounts/#{resource}/counts", actor: actor, body: {account_id: [id(:child)]}), false) }
      end
    end
  end

  it 'group and membership exact grants stay on one group, combine per target, and require membership' do
    phases do
      {group: ['groups', 'group_'], membership: ['group_users', 'membership_']}.each_value do |resource, prefix|
        %w[exact_child peer mixed group_account group_wrong_scope group_wrong_permission].each do |actor|
          TARGETS.each do |target|
            allowed = actor == 'group_account' ? %i[child leaf].include?(target) : !%w[group_wrong_scope group_wrong_permission].include?(actor) && (target == :child || (actor == 'mixed' && target == :sibling))
            check(call('group-service', "/#{resource}/#{id("#{prefix}#{target}")}", actor: actor), allowed, ids: [id("#{prefix}#{target}")])
          end
          peer_id = id("#{prefix}child_peer")
          check(call('group-service', "/#{resource}/#{peer_id}", actor: actor), actor == 'group_account', ids: [peer_id])
          [[ :child, :sibling ], [ :sibling, :child ]].each do |targets|
            ids = targets.map { |t| id("#{prefix}#{t}") }
            check(call('group-service', "/#{resource}/search", actor: actor, body: {id: ids}), actor == 'mixed', ids: ids)
          end
        end
      end
      # A group grant cannot authorize its user's record or the owning account.
      check(call('user-service', "/users/#{id(:user_child)}", actor: 'exact_child'), false)
      check(call('account-service', "/accounts/#{id(:child)}", actor: 'exact_child'), false)
    end
  end

  it 'membership user filters authorize the group owner rather than the member user account' do
    phases do
      response = call('group-service', '/group_users/search', actor: 'users_foreign_provider', body: {user_id: [id('actor_nonmember')]})
      check(response, false)
      check(call('group-service', '/group_users/search', actor: 'users_child', body: {group_id: [id(:group_child)]}), true, ids: [id(:membership_child)])
      check(call('group-service', "/group_users?group_id=#{id(:group_child)}", actor: 'users_child'), true, ids: [id(:membership_child)])
    end
  end

  it 'hierarchy records require authority on every returned ancestor as well as requested accounts' do
    phases do
      { 'read_child' => false, 'read_leaf' => false, 'read_root' => true, 'read_provider' => true,
        'read_provider_root' => true, 'read_sibling' => false, 'read_foreign_provider' => false,
        'users_root' => false, 'read_wrong_scope' => false, 'nonmember' => false }.each do |actor, allowed|
        expected = %i[root child leaf].map { |t| id(t) }
        check(call('account-service', "/account_with_parents/#{id(:leaf)}", actor: actor), allowed, ids: expected)
        check(call('account-service', '/accounts_with_parents', actor: actor, body: {account_ids: [id(:leaf)]}), allowed, ids: expected)
        check(call('account-service', "/accounts_with_parents?account_ids[]=#{id(:leaf)}", actor: actor), allowed, ids: expected)
      end
      [[id(:leaf), id(:foreign)], [id(:foreign), id(:leaf)]].each do |ids|
        check(call('account-service', '/accounts_with_parents', actor: 'read_provider_root', body: {account_ids: ids}), false)
      end
    end
  end

  it 'organization records and account enumeration require their distinct exact organization grants' do
    phases do
      F::ORGANIZATIONS.each do |org, accounts|
        %w[org list].each do |permission|
          F::ORGANIZATIONS.each_key do |grant_scope|
            actor = "#{permission}_#{grant_scope}"
            check(call('organization-service', "/organizations/#{id(org)}", actor: actor), permission == 'org' && org == grant_scope, ids: [id(org)])
            check(call('organization-service', "/organization_accounts?organization_id=#{id(org)}", actor: actor), permission == 'list' && org == grant_scope, ids: accounts.map { |a| id("link_#{a}") })
            response = call('organization-service', "/organizations/accounts/counts/#{id(org)}", actor: actor)
            check(response, permission == 'list' && org == grant_scope)
            expect(json(response)).to eq('organization_id' => id(org), 'accounts_count' => accounts.size) if response.code == '200'
          end
        end
      end
      %w[org_wrong_scope list_wrong_scope read_provider_root users_provider_root nonmember].each do |actor|
        check(call('organization-service', "/organizations/#{id(:client)}", actor: actor), false)
        check(call('organization-service', "/organizations/accounts/counts/#{id(:client)}", actor: actor), false)
      end
      TARGETS.first(5).each do |target|
        check(call('organization-service', "/organization_accounts/#{id("link_#{target}")}", actor: 'list_client'), true, ids: [id("link_#{target}")])
        check(call('organization-service', "/organization_accounts/#{id("link_#{target}")}", actor: 'org_client'), false)
      end
      check(call('organization-service', "/organizations/#{id(:client)}", actor: nil), false)
      check(call('organization-service', "/organizations/accounts/counts/#{id(:client)}", actor: nil), false)
      # Listing every row by account grants is allowed only if every row is covered.
      check(call('organization-service', "/organization_accounts?organization_id=#{id(:client)}", actor: 'read_child'), false)
      check(call('organization-service', "/organization_accounts?organization_id=#{id(:client)}", actor: 'read_provider'), true, ids: F::ORGANIZATIONS.fetch(:client).map { |a| id("link_#{a}") })
    end
  end

  it 'organization context requires account read AND enumeration, plus organization read when embedding the record' do
    phases do
      %w[read_provider_root list_client org_client users_provider_root nonmember].each do |actor|
        check(call('organization-service', '/organization_account_ids/for_account_ids', actor: actor, body: {account_ids: [id(:child)]}), false)
        check(call('organization-service', "/organization_account_ids/for_account_id/#{id(:child)}", actor: actor), false)
      end
      check(call('organization-service', '/organization_account_ids/for_account_ids', actor: 'read_list', body: {account_ids: [id(:child)]}), true)
      %w[read_list read_org list_org].each { |actor| check(call('organization-service', "/organization_account_ids/for_account_id/#{id(:child)}", actor: actor), false) }
      response = call('organization-service', '/organization_account_ids/for_account_ids', actor: 'full', body: {account_ids: [id(:child)]})
      check(response, true)
      payload = json(response)
      expect(payload.fetch('account_to_organization')).to eq(id(:child) => id(:client))
      expect(payload.fetch('organizations').fetch(id(:client))).to match_array(F::ORGANIZATIONS.fetch(:client).map { |a| id(a) })
      response = call('organization-service', "/organization_account_ids/for_account_id/#{id(:child)}", actor: 'full')
      check(response, true)
      expect(json(response).fetch('organization').fetch('id')).to eq(id(:client))
      expect(json(response).fetch('account_ids')).to match_array(F::ORGANIZATIONS.fetch(:client).map { |a| id(a) })
      check(call('organization-service', '/organization_account_ids/for_account_ids', actor: 'full', body: {account_ids: [id(:child), id(:foreign)]}), false)
    end
  end

  it 'MSP pages require the actual permission on the provider and each managed target, never a role or unrelated grant' do
    phases do
      %w[read_provider read_provider_root full].each do |actor|
        cursor = nil
        seen = []
        loop do
          path = "/msp_managed_organizations/#{id(:provider)}?limit=2"
          path += "&continuance=#{cursor}" if cursor
          response = call('organization-service', path, actor: actor)
          check(response, true)
          page = json(response)
          expect(page.fetch('total_count')).to eq(6)
          expect(page.fetch('msp_organization_id')).to eq(id(:provider_org))
          seen.concat(page.fetch('managed_account_ids'))
          cursor = page.fetch('continuance')
          break unless cursor
        end
        expect(seen).to match_array(%i[root child leaf sibling detached second_client].map { |t| id(t) })
      end
      %w[read_child read_foreign_provider users_provider org_provider_org list_provider_org nonmember].each do |actor|
        check(call('organization-service', "/msp_managed_organizations/#{id(:provider)}?limit=2", actor: actor), false)
      end
    end
  end

  it 'capability lists and can match the independent per-target oracle for Account, Group and Organization' do
    phases do
      COVERAGE.each do |scope, allowed_targets|
        %i[read users].each do |permission|
          actor = "#{permission}_#{scope}"
          %w[Account Group].each do |type|
            targets = TARGETS.map { |t| id(type == 'Group' ? "group_#{t}" : t) }
            expected = TARGETS.to_h { |t| [id(type == 'Group' ? "group_#{t}" : t), allowed_targets.include?(t) ? [F::PERMISSIONS.fetch(permission)] : []] }
            response = call('authorization-service', "/capabilities/#{type}", actor: actor, body: {scope_id: targets})
            expect(response.code).to eq('200')
            expect(json(response)).to eq(expected)
            expected.each do |target, capabilities|
              response = call('authorization-service', "/capabilities/#{type}/#{target}", actor: actor)
              expect(response.code).to eq('200')
              expect(json(response)).to eq(capabilities)
              next if ENV['AUTHORIZATION_CHECK_MODE'] == 'capabilities'
              check(call('authorization-service', "/can/#{type}/#{F::PERMISSIONS.fetch(permission)}", actor: actor, body: {scope_id: [target]}), !capabilities.empty?)
            end
          end
        end
      end
      %w[org list].each do |permission|
        targets = F::ORGANIZATIONS.keys.map { |t| id(t) }
        expected = F::ORGANIZATIONS.keys.to_h { |t| [id(t), t == :client ? [F::PERMISSIONS.fetch(permission.to_sym)] : []] }
        response = call('authorization-service', '/capabilities/Organization', actor: "#{permission}_client", body: {scope_id: targets})
        expect(json(response)).to eq(expected)
        expected.each do |target, capabilities|
          expect(json(call('authorization-service', "/capabilities/Organization/#{target}", actor: "#{permission}_client"))).to eq(capabilities)
          next if ENV['AUTHORIZATION_CHECK_MODE'] == 'capabilities'
          check(call('authorization-service', "/can/Organization/#{F::PERMISSIONS.fetch(permission.to_sym)}", actor: "#{permission}_client", body: {scope_id: [target]}), !capabilities.empty?)
        end
      end
      response = call('authorization-service', '/can/Account/account.read', actor: 'read_child', body: {scope_id: [id(:child)]})
      expect(response.code).to eq(ENV['AUTHORIZATION_CHECK_MODE'] == 'capabilities' ? '503' : '200')
    end
  end

  it 'internal record and relationship lookups reject real actors and the wrong trusted context' do
    routes = [
      ['group-service', '/internal/auth/memberships', {user_id: id('actor_full')}, 'IAM_SYSTEM'],
      ['group-service', '/internal/auth/group_contexts', {group_ids: [id(:group_child)]}, 'IAM_SYSTEM'],
      ['organization-service', '/internal/auth/account_contexts', {contexts: [{msp_organization_id: id(:provider_org), msp_account_id: id(:provider), accounts: [{account_id: id(:child), parent_account_ids: [id(:root)]}]}]}, 'IAM_SYSTEM'],
      ['organization-service', '/internal/auth/account_providers', {account_ids: [id(:child)]}, 'IAM_SYSTEM'],
      ['organization-service', '/internal/random/organization', nil, 'IAM_SYSTEM_AUTH'],
      ['organization-service', "/internal/random/organizations/#{id(:client)}/account", nil, 'IAM_SYSTEM_AUTH'],
      ['organization-service', "/internal/msp_managed_organizations/#{id(:provider)}", nil, 'IAM_SYSTEM_AUTH'],
      ['authorization-service', "/internal/admin_users/organization/#{id(:client)}", nil, 'IAM_SYSTEM_AUTH']
    ]
    routes.each do |service, path, body, wrong_context|
      check(call(service, path, actor: 'full', body: body), false)
      check(call(service, path, actor: nil, body: body), false)
      check(call(service, path, actor: nil, body: body, headers: {'pad-user-id' => wrong_context}), false)
    end
  end
  it 'zero counts still require authority on the requested empty account' do
    phases do
      %w[users groups].each do |resource|
        service = resource == 'users' ? 'user-service' : 'group-service'
        check(call(service, "/accounts/#{resource}/counts", actor: 'users_empty', body: {account_id: [id(:empty)]}), true, count: {id(:empty) => 0})
        %w[users_child read_empty nonmember].each do |actor|
          check(call(service, "/accounts/#{resource}/counts", actor: actor, body: {account_id: [id(:empty)]}), false)
        end
      end
    end
  end

  it 'GraphQL checks organization, account, nested user, membership, group and count reads as the specified actor' do
    phases do
      account_fields = 'id usersCount groupsCount users { id groups { id } }'
      {nested: true, full: false, read_provider_root: false, users_provider_root: false, nonmember: false}.each do |actor, allowed|
        query = "{ account(id: \"#{id(:child)}\", as: \"#{id("actor_#{actor}")}\") { #{account_fields} } }"
        response = json(call('user-management-service', '/graphql', actor: nil, body: {query: query}))
        if allowed
          expect(response['errors']).to be_nil
          expect(response.fetch('data').fetch('account')).to eq('id' => id(:child), 'usersCount' => 1, 'groupsCount' => 2, 'users' => [{'id' => id(:user_child), 'groups' => [{'id' => id(:group_foreign)}]}])
        else
          expect(response.fetch('errors')).not_to be_empty
          expect(response.fetch('data')).to eq('account' => nil)
        end
      end
      {full: true, org_client: false, list_client: false, read_provider_root: false}.each do |actor, allowed|
        query = "{ organization(id: \"#{id(:client)}\", as: \"#{id("actor_#{actor}")}\") { id accountsCount accounts { id } } }"
        response = json(call('user-management-service', '/graphql', actor: nil, body: {query: query}))
        if allowed
          expect(response['errors']).to be_nil
          org = response.fetch('data').fetch('organization')
          expect(org.fetch('id')).to eq(id(:client))
          expect(org.fetch('accountsCount')).to eq(5)
          expect(org.fetch('accounts').map { |a| a.fetch('id') }).to match_array(TARGETS.first(5).map { |a| id(a) })
        else
          expect(response.fetch('errors')).not_to be_empty
          expect(response.fetch('data')).to eq('organization' => nil)
        end
      end
    end
  end

  it 'each GraphQL count field preserves its actor and reports authorization denial as a field error' do
    phases do
      %w[usersCount groupsCount].each do |field|
        {full: true, read_provider_root: false}.each do |actor, allowed|
          query = "{ account(id: \"#{id(:child)}\", as: \"#{id("actor_#{actor}")}\") { #{field} } }"
          response = call('user-management-service', '/graphql', actor: nil, body: {query: query})
          expect(response.code).to eq('200')
          payload = json(response)
          if allowed
            expect(payload['errors']).to be_nil
            expect(payload.fetch('data').fetch('account')).to eq(field => (field == 'groupsCount' ? 2 : 1))
          else
            expect(payload.fetch('errors')).not_to be_empty
            expect(payload.fetch('data')).to eq('account' => nil)
          end
        end
      end
      allowed = "allowed: organization(id: \"#{id(:client)}\", as: \"#{id('actor_full')}\") { accountsCount }"
      denied = "denied: organization(id: \"#{id(:client)}\", as: \"#{id('actor_org_client')}\") { accountsCount }"
      [[allowed, denied], [denied, allowed]].each do |fields|
        response = call('user-management-service', '/graphql', actor: nil, body: {query: "{ #{fields.join(' ')} }"})
        expect(response.code).to eq('200')
        payload = json(response)
        expect(payload.fetch('data')).to eq('allowed' => {'accountsCount' => 5}, 'denied' => nil)
        expect(payload.fetch('errors').map { |e| e.fetch('path').first }).to eq(['denied'])
      end
    end
  end

  it 'trusted authorization facts return exact owners and only actual MSP relationships' do
    headers = {'pad-user-id' => 'IAM_SYSTEM_AUTH'}
    response = call('group-service', '/internal/auth/group_contexts', actor: nil, body: {group_ids: [id(:group_child), id(:group_foreign)]}, headers: headers)
    check(response, true)
    expect(json(response).fetch('groups')).to match_array([
      {'id' => id(:group_child), 'account_id' => id(:child)}, {'id' => id(:group_foreign), 'account_id' => id(:foreign)}])
    response = call('group-service', '/internal/auth/memberships', actor: nil, body: {user_id: id('actor_read_child')}, headers: headers)
    check(response, true)
    expect(json(response)).to eq('memberships' => [{'group_id' => id('grant_group_read_child'), 'user_id' => id('actor_read_child')}])
    response = call('organization-service', '/internal/auth/account_providers', actor: nil, body: {account_ids: [id(:child), id(:foreign), id(:empty)]}, headers: headers)
    check(response, true)
    expect(json(response).fetch('accounts')).to match_array([
      {'account_id' => id(:child), 'msp_account_id' => id(:provider), 'msp_organization_id' => id(:provider_org), 'client_organization_id' => id(:client)},
      {'account_id' => id(:foreign), 'msp_account_id' => id(:foreign_provider), 'msp_organization_id' => id(:other_provider_org), 'client_organization_id' => id(:other_client)}])
    context = {msp_organization_id: id(:provider_org), msp_account_id: id(:provider), accounts: [
      {account_id: id(:child), parent_account_ids: [id(:root), id(:foreign), id(:provider)]},
      {account_id: id(:foreign), parent_account_ids: []}]}
    response = call('organization-service', '/internal/auth/account_contexts', actor: nil, body: {contexts: [context]}, headers: headers)
    check(response, true)
    expect(json(response)).to eq('accounts' => [{'account_id' => id(:child), 'msp_account_id' => id(:provider), 'msp_organization_id' => id(:provider_org), 'client_organization_id' => id(:client), 'parent_account_ids' => [id(:root)]}])
  end

  it 'HTML account loading variants preserve the actor across every downstream record type' do
    phases do
      %w[accounts slow_accounts slowest_accounts].each do |path|
        response = call('user-management-service', "/#{path}/#{id(:child)}?as=#{id('actor_nested')}", actor: nil)
        check(response, true)
        expect(response.body).to include(id(:child))
        expect(response.body).not_to include(id(:foreign))
        %w[read_child users_provider_root nonmember].each do |actor|
          check(call('user-management-service', "/#{path}/#{id(:child)}?as=#{id("actor_#{actor}")}", actor: nil), false)
        end
      end
    end
  end

end
