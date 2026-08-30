require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe Authorization::Capabilities do
  class FakeCapabilitiesRedis
    attr_reader :sets, :pipelines

    def initialize
      @values = {}
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

    def get(key)
      result = @values[key]
      @active_pipeline << { command: :get, key: key, result: result } if @active_pipeline
      result
    end

    def set(key, value, ex:)
      @sets << [key, value, ex]
      @values[key] = value
      @active_pipeline << { command: :set, key: key, value: value, ex: ex, result: "OK" } if @active_pipeline
      "OK"
    end
  end

  class FakeAccountContextClient
    attr_reader :contexts

    def initialize(valid_msp_account_id:)
      @valid_msp_account_id = valid_msp_account_id
      @contexts = nil
    end

    def account_contexts(contexts:)
      @contexts = contexts
      {
        "accounts" => contexts.filter_map do |context|
          next unless context.fetch(:msp_account_id) == @valid_msp_account_id

          {
            "msp_organization_id" => context.fetch(:msp_organization_id),
            "msp_account_id" => context.fetch(:msp_account_id),
            "client_organization_id" => SecureRandom.uuid,
            "account_id" => context.fetch(:accounts).first.fetch(:account_id),
            "parent_account_ids" => context.fetch(:accounts).first.fetch(:parent_account_ids)
          }
        end
      }
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

  it "caches final capability arrays for five minutes" do
    CapabilityGrant.create!(
      user_id: user_id,
      permission: "organization.read.accounts",
      scope_type: "Organization",
      scope_id: organization_id
    )

    expect(service.for_organization(organization_id)).to eq(["organization.read.accounts"])
    expect(redis.sets).to contain_exactly(
      [
        "capabilities:#{user_id}:Organization:#{organization_id}",
        "[\"organization.read.accounts\"]",
        300
      ]
    )

    CapabilityGrant.delete_all
    expect(service.for_organization(organization_id)).to eq(["organization.read.accounts"])
  end

  it "reflects only the MSP account grants returned by the organization auth context" do
    msp_organization_id = SecureRandom.uuid
    msp_account_1_id = SecureRandom.uuid
    msp_account_2_id = SecureRandom.uuid
    client_root_account_id = SecureRandom.uuid
    client_target_account_id = SecureRandom.uuid
    context_client = FakeAccountContextClient.new(valid_msp_account_id: msp_account_1_id)
    service = described_class.new(
      user_id: user_id,
      redis: IamDemo::NullRedisCache.new,
      account_context_client: context_client
    )

    CapabilityGrant.create!(user_id: user_id, permission: "msp.admin.users", scope_type: "Organization", scope_id: msp_organization_id)
    CapabilityGrant.create!(user_id: user_id, permission: "account.users.read", scope_type: "Account", scope_id: msp_account_1_id)
    CapabilityGrant.create!(user_id: user_id, permission: "account.users.create", scope_type: "Account", scope_id: msp_account_2_id)
    CapabilityGrant.create!(user_id: user_id, permission: "msp.account.secret", scope_type: "Account", scope_id: msp_account_1_id)
    CapabilityGrant.create!(user_id: user_id, permission: "do.some.mcguffin", scope_type: "Account", scope_id: client_target_account_id)

    allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
    allow(Account).to receive(:with_parents_batch).with([client_target_account_id]).and_return(
      [[OpenStruct.new(id: client_root_account_id), OpenStruct.new(id: client_target_account_id)]]
    )

    expect(service.for_account(client_target_account_id)).to eq(["account.users.read", "do.some.mcguffin"])
    expect(context_client.contexts.map { |context| context.fetch(:msp_account_id) }).to contain_exactly(msp_account_1_id, msp_account_2_id)
  end

  it "pipelines multi-account permission cache reads and computed writes" do
    permission = "account.users.read"
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    CapabilityGrant.create!(
      user_id: user_id,
      permission: permission,
      scope_type: "Account",
      scope_id: account_ids.first
    )
    allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
    allow(Account).to receive(:with_parents_batch).with(account_ids).and_return(
      account_ids.map { |account_id| [OpenStruct.new(id: account_id)] }
    )

    expect(service.account_ids_with_permission(account_ids, permission)).to eq(Set[account_ids.first])

    expect(redis.pipelines.map { |operations| operations.map { |operation| operation.fetch(:command) } }).to eq(
      [%i[get get], %i[set set]]
    )
    expect(redis.sets).to contain_exactly(
      ["can:#{user_id}:Account:#{permission}:#{account_ids.first}", "true", 300],
      ["can:#{user_id}:Account:#{permission}:#{account_ids.last}", "false", 300]
    )
  end

  it "uses positive and negative cache hits while computing only misses" do
    permission = "account.users.read"
    positive_id = SecureRandom.uuid
    negative_id = SecureRandom.uuid
    missing_id = SecureRandom.uuid
    redis.seed("can:#{user_id}:Account:#{permission}:#{positive_id}", "true")
    redis.seed("can:#{user_id}:Account:#{permission}:#{negative_id}", "false")
    allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
    allow(Account).to receive(:with_parents_batch).with([missing_id]).and_return(
      [[OpenStruct.new(id: missing_id)]]
    )

    result = service.account_ids_with_permission(
      [positive_id, negative_id, missing_id, positive_id],
      permission
    )

    expect(result).to eq(Set[positive_id])
    expect(redis.pipelines.first.map { |operation| operation.fetch(:key) }).to eq(
      [positive_id, negative_id, missing_id].map { |account_id| "can:#{user_id}:Account:#{permission}:#{account_id}" }
    )
    expect(redis.pipelines.last.map { |operation| operation.fetch(:key) }).to eq(
      ["can:#{user_id}:Account:#{permission}:#{missing_id}"]
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
      user_id: user_id,
      permission: permission,
      scope_type: "Account",
      scope_id: account_id
    )
    allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
    allow(Account).to receive(:with_parents_batch).with([account_id]).and_return(
      [[OpenStruct.new(id: account_id)]]
    )
    failing_service = described_class.new(user_id: user_id, redis: FailingCapabilitiesRedis.new)

    expect(failing_service.account_ids_with_permission([account_id], permission)).to eq(Set[account_id])
  end
end
