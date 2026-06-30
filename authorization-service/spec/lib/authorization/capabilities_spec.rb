require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe Authorization::Capabilities do
  class FakeCapabilitiesRedis
    attr_reader :sets

    def initialize
      @values = {}
      @sets = []
    end

    def get(key)
      @values[key]
    end

    def set(key, value, ex:)
      @sets << [key, value, ex]
      @values[key] = value
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
end
