require "rails_helper"
require "securerandom"
require "set"

RSpec.describe Authorization::MspReflectedUserGrants do
  class FakeMspRedis
    attr_reader :sets, :hashes

    def initialize
      @sets = Hash.new { |h, k| h[k] = Set.new }
      @hashes = Hash.new { |h, k| h[k] = {} }
    end

    def mapped_hmset(key, attrs)
      @hashes[key].merge!(attrs.transform_keys(&:to_s).transform_values(&:to_s))
    end

    def hgetall(key)
      @hashes[key]
    end

    def sadd(key, values)
      Array(values).each { |value| @sets[key] << value.to_s }
    end

    def sismember(key, value)
      @sets[key].include?(value.to_s)
    end

    def pipelined
      owner = self
      results = []
      pipe = Object.new
      pipe.define_singleton_method(:sismember) { |key, value| results << owner.sismember(key, value) }
      yield pipe
      results
    end

    def del(key)
      @sets.delete(key)
    end

    def expire(_key, _ttl)
      true
    end
  end

  let(:redis) { FakeMspRedis.new }
  let(:organization_client) { instance_double(Authorization::MspManagedAccountsClient) }
  let(:service) { described_class.new(redis: redis, organization_client: organization_client) }
  let(:user_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }
  let(:managed_account_ids) { Array.new(3) { SecureRandom.uuid } }

  it "loads reflected grants into Redis without native customer grants" do
    CapabilityGrant.create!(
      user_id: user_id,
      permission: "account.users.create",
      scope_type: "Account",
      scope_id: msp_account_id
    )
    allow(organization_client).to receive(:page).with(msp_account_id: msp_account_id).and_return(
      {
        "total_count" => managed_account_ids.length,
        "continuance" => "next-page",
        "managed_account_ids" => managed_account_ids.first(2)
      }
    )
    allow(organization_client).to receive(:page).with(msp_account_id: msp_account_id, continuance: "next-page").and_return(
      {
        "total_count" => managed_account_ids.length,
        "managed_account_ids" => managed_account_ids.last(1)
      }
    )

    service.load!(user_id: user_id, msp_account_id: msp_account_id)
    result = service.check(user_id: user_id, msp_account_id: msp_account_id, account_ids: managed_account_ids)

    expect(result.fetch(:loading)).to eq(false)
    expect(result.fetch(:authorized_account_ids)).to match_array(managed_account_ids)
    expect(CapabilityGrant.where(user_id: user_id, scope_id: managed_account_ids)).not_to exist
  end

  it "marks ready with no reflected accounts when the MSP native grant is missing" do
    allow(organization_client).to receive(:page).and_return(
      {
        "total_count" => managed_account_ids.length,
        "managed_account_ids" => managed_account_ids
      }
    )

    service.load!(user_id: user_id, msp_account_id: msp_account_id)
    result = service.check(user_id: user_id, msp_account_id: msp_account_id, account_ids: managed_account_ids)

    expect(result.fetch(:loading)).to eq(false)
    expect(result.fetch(:authorized_account_ids)).to be_empty
    expect(result.fetch(:total_count)).to eq(managed_account_ids.length)
  end
end
