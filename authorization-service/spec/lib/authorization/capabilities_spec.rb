require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe Authorization::Capabilities do
  def grant_group_id(actor)
    @grant_group_ids ||= {}
    @grant_group_ids[actor] ||= SecureRandom.uuid
  end

  before do
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).and_return({"accounts" => []})
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for) do |_client, actor|
      [grant_group_id(actor)]
    end
  end

  class FakeCapabilitiesRedis
    attr_reader :sets, :pipelines

    def initialize
      @values = {}
      @expires = {}
      @now = 0
      @sets = []
      @pipelines = []
      @active_pipeline = nil
    end

    def seed(key, value)
      @values[key] = value
    end

    def pipelined
      operations = []
      @active_pipeline = operations
      yield self
      @pipelines << operations
      operations.map { |operation| operation.fetch(:result) }
    ensure
      @active_pipeline = nil
    end

    def advance(seconds)
      @now += seconds
    end

    def get(key)
      @values.delete(key) if @expires[key] && @expires[key] <= @now
      result = @values[key]
      @active_pipeline << { command: :get, key: key, result: result } if @active_pipeline
      result
    end

    def set(key, value, ex:)
      @sets << [key, value, ex]
      @values[key] = value
      @expires[key] = @now + ex
      @active_pipeline << { command: :set, key: key, value: value, ex: ex, result: "OK" } if @active_pipeline
      "OK"
    end
  end

  class FailingCapabilitiesRedis
    def redis_enabled?
      true
    end

    def pipelined
      raise Redis::BaseError, "cache unavailable"
    end
  end

  let(:user_id) { SecureRandom.uuid }
  let(:organization_id) { SecureRandom.uuid }
  let(:redis) { FakeCapabilitiesRedis.new }
  let(:service) { described_class.new(user_id: user_id, redis: redis) }

  it "resolves distinct group owners in one relationship batch and reuses warm group results" do
    member_group = grant_group_id(user_id)
    group_ids = [SecureRandom.uuid, SecureRandom.uuid]
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    CapabilityGrant.create!(
      group_id: member_group,
      permission: "group.read",
      scope_type: "Group",
      scope_id: group_ids.first
    )
    CapabilityGrant.create!(
      group_id: member_group,
      permission: "account.users.read",
      scope_type: "Account",
      scope_id: account_ids.last
    )
    group_client = instance_double(Authorization::GroupContextClient)
    expect(group_client).to receive(:group_ids_for).with(user_id).once.and_return([member_group])
    expect(group_client).to receive(:groups).with(group_ids).once.and_return(
      group_ids.zip(account_ids).map { |group_id, account_id| {"id" => group_id, "account_id" => account_id} }
    )
    account_client = instance_double(Authorization::AccountContextClient)
    expect(account_client).to receive(:providers_for).with(account_ids: account_ids).once.and_return({"accounts" => []})
    expect(Account).to receive(:with_parents_batch).with(account_ids).once.and_return(
      account_ids.map { |account_id| [OpenStruct.new(id: account_id, parent_account_id: nil)] }
    )
    grouped = described_class.new(
      user_id: user_id, redis: redis, account_context_client: account_client, group_context_client: group_client
    )
    expected = {
      group_ids.first => ["group.read"],
      group_ids.last => ["account.users.read", "group.read"]
    }

    expect(grouped.for_groups(group_ids)).to eq(expected)
    expect(grouped.for_groups(group_ids)).to eq(expected)
  end

  it "caches final capability arrays for five minutes" do
    CapabilityGrant.create!(
      group_id: grant_group_id(user_id),
      permission: "organization.read.accounts",
      scope_type: "Organization",
      scope_id: organization_id
    )

    expect(service.for_organization(organization_id)).to eq(["organization.read.accounts"])
    expect(redis.sets).to contain_exactly(
      [
        "group-grants-v2:capabilities:#{user_id}:Organization:#{organization_id}",
        "[\"organization.read.accounts\"]",
        300
      ]
    )

    CapabilityGrant.delete_all
    expect(service.for_organization(organization_id)).to eq(["organization.read.accounts"])
  end

  it "inherits ordinary grants through provider ancestors without an MSP permission" do
    provider_root, provider, client_root, target, unrelated = Array.new(5) { SecureRandom.uuid }
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.users.read", scope_type: "Account", scope_id: provider_root)
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.users.create", scope_type: "Account", scope_id: unrelated)
    allow(Account).to receive(:with_parents_batch).with([target]).and_return([[
      OpenStruct.new(id: client_root, parent_account_id: nil), OpenStruct.new(id: target, parent_account_id: client_root)
    ]])
    allow(Account).to receive(:with_parents_batch).with([provider]).and_return([[
      OpenStruct.new(id: provider_root, parent_account_id: nil), OpenStruct.new(id: provider, parent_account_id: provider_root)
    ]])
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).with(account_ids: [target])
      .and_return({"accounts" => [{"account_id" => target, "msp_account_id" => provider}]})
    expect(service.for_account(target)).to eq(["account.users.read"])
    expect(service.account_ids_with_permission([target], "account.users.read")).to eq(Set[target])
    expect(service.account_ids_with_permission([target], "account.users.create")).to be_empty
  end

  it "pipelines multi-account permission cache reads and computed writes" do
    permission = "account.users.read"
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    CapabilityGrant.create!(
      group_id: grant_group_id(user_id),
      permission: permission,
      scope_type: "Account",
      scope_id: account_ids.first
    )
    allow(Account).to receive(:with_parents_batch).with(account_ids).and_return(
      account_ids.map { |account_id| [OpenStruct.new(id: account_id)] }
    )

    expect(service.account_ids_with_permission(account_ids, permission)).to eq(Set[account_ids.first])

    expect(redis.pipelines.map { |operations| operations.map { |operation| operation.fetch(:command) } }).to eq(
      [%i[get get], %i[set set]]
    )
    expect(redis.sets).to contain_exactly(
      ["group-grants-v2:can:#{user_id}:Account:#{permission}:#{account_ids.first}", "true", 300],
      ["group-grants-v2:can:#{user_id}:Account:#{permission}:#{account_ids.last}", "false", 300]
    )
  end

  it "does not reuse cached decisions from the former user-grant model" do
    account_id = SecureRandom.uuid
    redis.seed("can:#{user_id}:Account:account.read:#{account_id}", "true")
    redis.seed("capabilities:#{user_id}:Account:#{account_id}", '["account.read"]')
    allow(Account).to receive(:with_parents_batch).and_return([[OpenStruct.new(id: account_id, parent_account_id: nil)]])
    expect(service.account_ids_with_permission([account_id], "account.read")).to be_empty
    expect(service.for_account(account_id)).to eq([])
  end

  it "uses positive and negative cache hits while computing only misses" do
    permission = "account.users.read"
    positive_id = SecureRandom.uuid
    negative_id = SecureRandom.uuid
    missing_id = SecureRandom.uuid
    redis.seed("group-grants-v2:can:#{user_id}:Account:#{permission}:#{positive_id}", "true")
    redis.seed("group-grants-v2:can:#{user_id}:Account:#{permission}:#{negative_id}", "false")
    allow(Account).to receive(:with_parents_batch).with([missing_id]).and_return(
      [[OpenStruct.new(id: missing_id)]]
    )

    result = service.account_ids_with_permission(
      [positive_id, negative_id, missing_id, positive_id],
      permission
    )

    expect(result).to eq(Set[positive_id])
    expect(redis.pipelines.first.map { |operation| operation.fetch(:key) }).to eq(
      [positive_id, negative_id, missing_id].map { |account_id| "group-grants-v2:can:#{user_id}:Account:#{permission}:#{account_id}" }
    )
    expect(redis.pipelines.last.map { |operation| operation.fetch(:key) }).to eq(
      ["group-grants-v2:can:#{user_id}:Account:#{permission}:#{missing_id}"]
    )
  end

  it "does not access Redis or account hierarchy data for empty input" do
    expect(Account).not_to receive(:with_parents_batch)

    expect(service.account_ids_with_permission([], "account.users.read")).to be_empty
    expect(redis.pipelines).to be_empty
  end

  it "falls back to authoritative computation when Redis pipelines fail" do
    permission = "account.users.read"
    account_id = SecureRandom.uuid
    CapabilityGrant.create!(
      group_id: grant_group_id(user_id),
      permission: permission,
      scope_type: "Account",
      scope_id: account_id
    )
    allow(Account).to receive(:with_parents_batch).with([account_id]).and_return(
      [[OpenStruct.new(id: account_id)]]
    )
    failing_service = described_class.new(user_id: user_id, redis: FailingCapabilitiesRedis.new)

    expect(failing_service.account_ids_with_permission([account_id], permission)).to eq(Set[account_id])
  end

  it "maps reordered hierarchy responses by their target account IDs" do
    permission = "account.users.read"
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    account_ids.each do |account_id|
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: permission, scope_type: "Account", scope_id: account_id)
    end
    allow(Account).to receive(:with_parents_batch).with(account_ids).and_return(
      account_ids.reverse.map { |account_id| [OpenStruct.new(id: account_id, parent_account_id: nil)] }
    )

    expect(service.account_ids_with_permission(account_ids, permission)).to eq(account_ids.to_set)
  end

  it "denies missing and duplicated hierarchy targets" do
    permission = "account.users.read"
    present_id = SecureRandom.uuid
    missing_id = SecureRandom.uuid
    duplicated_id = SecureRandom.uuid
    [present_id, missing_id, duplicated_id].each do |account_id|
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: permission, scope_type: "Account", scope_id: account_id)
    end
    requested_ids = [present_id, missing_id, duplicated_id]
    allow(Account).to receive(:with_parents_batch).with(requested_ids).and_return(
      [
        [OpenStruct.new(id: duplicated_id, parent_account_id: nil)],
        [OpenStruct.new(id: present_id, parent_account_id: nil)],
        [OpenStruct.new(id: duplicated_id, parent_account_id: nil)]
      ]
    )

    expect(service.account_ids_with_permission(requested_ids, permission)).to eq(Set[present_id])
  end

  it "denies malformed, cyclic, and unexpectedly deep hierarchies" do
    permission = "account.users.read"
    malformed_id = SecureRandom.uuid
    cyclic_id = SecureRandom.uuid
    deep_id = SecureRandom.uuid
    malformed_root_id = SecureRandom.uuid
    cycle_root_id = SecureRandom.uuid
    deep_ids = Array.new(described_class::MAX_ACCOUNT_HIERARCHY_DEPTH) { SecureRandom.uuid } + [deep_id]
    deep_hierarchy = deep_ids.each_with_index.map do |id, index|
      OpenStruct.new(id: id, parent_account_id: index.zero? ? nil : deep_ids[index - 1])
    end
    requested_ids = [malformed_id, cyclic_id, deep_id]
    requested_ids.each do |account_id|
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: permission, scope_type: "Account", scope_id: account_id)
    end
    allow(Account).to receive(:with_parents_batch).with(requested_ids).and_return(
      [
        [
          OpenStruct.new(id: malformed_root_id, parent_account_id: nil),
          OpenStruct.new(id: malformed_id, parent_account_id: SecureRandom.uuid)
        ],
        [
          OpenStruct.new(id: cycle_root_id, parent_account_id: nil),
          OpenStruct.new(id: cyclic_id, parent_account_id: cycle_root_id),
          OpenStruct.new(id: cycle_root_id, parent_account_id: cyclic_id),
          OpenStruct.new(id: cyclic_id, parent_account_id: cycle_root_id)
        ],
        deep_hierarchy
      ]
    )

    expect(service.account_ids_with_permission(requested_ids, permission)).to be_empty
  end

  it "does not reflect grants onto an invalid hierarchy target" do
    target = SecureRandom.uuid
    allow(Account).to receive(:with_parents_batch).and_return([])
    expect_any_instance_of(Authorization::AccountContextClient).not_to receive(:providers_for)
    expect(service.account_ids_with_permission([target], "account.read")).to be_empty
  end

  it "rejects malformed account IDs without calling downstream services" do
    expect(Account).not_to receive(:with_parents_batch)

    expect(service.account_ids_with_permission(["not-a-uuid"], "account.users.read")).to be_empty
    expect(redis.pipelines).to be_empty
  end

  it "applies account grants downward but never upward or sideways" do
    permission = "account.users.read"
    root_id = SecureRandom.uuid
    granted_child_id = SecureRandom.uuid
    grandchild_id = SecureRandom.uuid
    sibling_id = SecureRandom.uuid
    hierarchies = {
      root_id => [OpenStruct.new(id: root_id, parent_account_id: nil)],
      granted_child_id => [
        OpenStruct.new(id: root_id, parent_account_id: nil),
        OpenStruct.new(id: granted_child_id, parent_account_id: root_id)
      ],
      grandchild_id => [
        OpenStruct.new(id: root_id, parent_account_id: nil),
        OpenStruct.new(id: granted_child_id, parent_account_id: root_id),
        OpenStruct.new(id: grandchild_id, parent_account_id: granted_child_id)
      ],
      sibling_id => [
        OpenStruct.new(id: root_id, parent_account_id: nil),
        OpenStruct.new(id: sibling_id, parent_account_id: root_id)
      ]
    }
    requested_ids = [root_id, granted_child_id, grandchild_id, sibling_id]
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: permission, scope_type: "Account", scope_id: granted_child_id)
    allow(Account).to receive(:with_parents_batch).with(requested_ids).and_return(
      requested_ids.reverse.map { |account_id| hierarchies.fetch(account_id) }
    )

    expect(service.account_ids_with_permission(requested_ids, permission)).to eq(
      Set[granted_child_id, grandchild_id]
    )
  end

  it "isolates cached decisions by actor and permission" do
    account_id = SecureRandom.uuid
    other_user_id = SecureRandom.uuid
    read_permission = "account.users.read"
    write_permission = "account.users.create"
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: read_permission, scope_type: "Account", scope_id: account_id)
    allow(Account).to receive(:with_parents_batch).with([account_id]).and_return(
      [[OpenStruct.new(id: account_id, parent_account_id: nil)]]
    )

    expect(described_class.new(user_id: user_id, redis: redis).account_ids_with_permission([account_id], read_permission)).to eq(Set[account_id])
    expect(described_class.new(user_id: other_user_id, redis: redis).account_ids_with_permission([account_id], read_permission)).to be_empty
    expect(described_class.new(user_id: user_id, redis: redis).account_ids_with_permission([account_id], write_permission)).to be_empty

    expect(redis.sets.map(&:first)).to contain_exactly(
      "group-grants-v2:can:#{user_id}:Account:#{read_permission}:#{account_id}",
      "group-grants-v2:can:#{other_user_id}:Account:#{read_permission}:#{account_id}",
      "group-grants-v2:can:#{user_id}:Account:#{write_permission}:#{account_id}"
    )
  end

  it "matches a depth-walk oracle over generated trees and grants" do
    random = Random.new(12_345)
    account_ids = Array.new(24) { SecureRandom.uuid }
    parent_by_id = { account_ids.first => nil }
    account_ids.drop(1).each_with_index do |account_id, index|
      parent_by_id[account_id] = account_ids[random.rand(0..index)]
    end
    hierarchy_for = lambda do |target_id|
      ids = []
      current_id = target_id
      while current_id
        ids.unshift(current_id)
        current_id = parent_by_id.fetch(current_id)
      end
      ids.each_with_index.map do |account_id, index|
        OpenStruct.new(id: account_id, parent_account_id: index.zero? ? nil : ids[index - 1])
      end
    end
    granted_ids = account_ids.sample(7, random: random).to_set
    permission = "account.users.read"
    granted_ids.each do |account_id|
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: permission, scope_type: "Account", scope_id: account_id)
    end
    allow(Account).to receive(:with_parents_batch) do |requested_ids|
      requested_ids.reverse.map { |account_id| hierarchy_for.call(account_id) }
    end
    generated_service = described_class.new(user_id: user_id, redis: IamDemo::NullRedisCache.new)

    30.times do
      requested_ids = account_ids.sample(random.rand(1..8), random: random)
      requested_ids << requested_ids.first if random.rand(2).zero?
      expected = requested_ids.to_set.select do |account_id|
        hierarchy_for.call(account_id).any? { |account| granted_ids.include?(account.id) }
      end.to_set

      expect(generated_service.account_ids_with_permission(requested_ids.shuffle(random: random), permission)).to eq(expected)
    end
  end
  it "observes grant revocation after the documented five-minute decision TTL, without refreshing a hit" do
    account_id = SecureRandom.uuid
    grant = CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.users.read", scope_type: "Account", scope_id: account_id)
    allow(Account).to receive(:with_parents_batch).with([account_id]).and_return([[Account.new(id: account_id, parent_account_id: nil)]])
    expect(service.for_account(account_id)).to eq(["account.users.read"])
    expect(service.account_ids_with_permission([account_id], "account.users.read")).to eq(Set[account_id])
    grant.destroy!
    redis.advance(299)
    expect(service.for_account(account_id)).to eq(["account.users.read"])
    expect(service.account_ids_with_permission([account_id], "account.users.read")).to eq(Set[account_id])
    redis.advance(1)
    expect(service.for_account(account_id)).to eq([])
    expect(service.account_ids_with_permission([account_id], "account.users.read")).to eq(Set.new)
  end

  it "never caches an allow when the hierarchy dependency fails" do
    target = SecureRandom.uuid
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: target)
    allow(Account).to receive(:with_parents_batch).and_raise(IOError, "owning service unavailable")
    expect { service.account_ids_with_permission([target], "account.read") }.to raise_error(IOError)
    expect(redis.sets).to eq([])
  end

  it "never treats an unavailable MSP relationship service as a wildcard relationship" do
    target, cohort, msp = Array.new(3) { SecureRandom.uuid }
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.users.manage", scope_type: "Organization", scope_id: msp)
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: cohort)
    allow(Account).to receive(:with_parents_batch) { |ids| ids.map { |id| [Account.new(id: id, parent_account_id: nil)] } }
    client = instance_double(Authorization::AccountContextClient)
    allow(client).to receive(:providers_for).and_raise(IOError, "relationship service unavailable")
    subject = described_class.new(user_id: user_id, redis: redis, account_context_client: client)
    expect { subject.account_ids_with_permission([target], "account.read") }.to raise_error(IOError)
    expect(redis.sets).to eq([])
  end

  it "expires cached MSP authority after a relationship removal and preserves direct account grants" do
    target, cohort, msp = Array.new(3) { SecureRandom.uuid }
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.users.manage", scope_type: "Organization", scope_id: msp)
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: cohort)
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "direct.read", scope_type: "Account", scope_id: target)
    allow(Account).to receive(:with_parents_batch) { |ids| ids.map { |id| [Account.new(id: id, parent_account_id: nil)] } }
    client = instance_double(Authorization::AccountContextClient)
    allow(client).to receive(:providers_for).and_return({"accounts" => []})
    allow(client).to receive(:providers_for).with(account_ids: [target]).and_return({"accounts" => [{"account_id" => target, "msp_account_id" => cohort}]})
    scoped = described_class.new(user_id: user_id, redis: redis, account_context_client: client)
    expect(scoped.for_account(target)).to eq(["account.read", "direct.read"])
    allow(client).to receive(:providers_for).with(account_ids: [target]).and_return({"accounts" => []})
    redis.advance(299)
    expect(scoped.for_account(target)).to eq(["account.read", "direct.read"])
    redis.advance(1)
    expect(scoped.for_account(target)).to eq(["direct.read"])
  end

  it "shares canonical cache entries between UUID spellings without changing requested result IDs" do
    account = "ab100000-0000-4000-8000-000000000001"
    CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: account)
    expect(Account).to receive(:with_parents_batch).with([account]).twice.and_return([[OpenStruct.new(id: account, parent_account_id: nil)]])
    2.times do
      [account.upcase, account].each do |spelling|
        expect(service.for_account(spelling)).to eq(["account.read"])
        expect(service.account_ids_with_permission([spelling], "account.read")).to eq(Set[spelling])
      end
    end
    expect(redis.sets.map(&:first)).to contain_exactly(
      "group-grants-v2:capabilities:#{user_id}:Account:#{account}",
      "group-grants-v2:can:#{user_id}:Account:account.read:#{account}"
    )
  end

end
