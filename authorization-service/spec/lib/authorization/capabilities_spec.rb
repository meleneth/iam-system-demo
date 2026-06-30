require "rails_helper"
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

  let(:user_id) { SecureRandom.uuid }
  let(:organization_id) { SecureRandom.uuid }
  let(:redis) { FakeCapabilitiesRedis.new }
  let(:service) { described_class.new(user_id: user_id, redis: redis) }

  it "caches final capability arrays for five minutes" do
    CapabilityGrant.create!(
      user_id: user_id,
      permission: "organization.accounts.read",
      scope_type: "Organization",
      scope_id: organization_id
    )

    expect(service.for_organization(organization_id)).to eq(["organization.accounts.read"])
    expect(redis.sets).to contain_exactly(
      [
        "capabilities:#{user_id}:Organization:#{organization_id}",
        "[\"organization.accounts.read\"]",
        300
      ]
    )

    CapabilityGrant.delete_all
    expect(service.for_organization(organization_id)).to eq(["organization.accounts.read"])
  end
end
