require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe "Capabilities", type: :request do
  let(:user_id) { SecureRandom.uuid }

  before do
    stub_const("AUTHORIZATION_CACHE", IamDemo::NullRedisCache.new)
  end

  describe "GET /capabilities/Organization/:organization_id" do
    it "returns direct organization-scoped capability names" do
      organization_id = SecureRandom.uuid
      other_organization_id = SecureRandom.uuid
      CapabilityGrant.create!(user_id: user_id, permission: "organization.accounts.read", scope_type: "Organization", scope_id: organization_id)
      CapabilityGrant.create!(user_id: user_id, permission: "msp.admin.users", scope_type: "Organization", scope_id: organization_id)
      CapabilityGrant.create!(user_id: user_id, permission: "organization.read", scope_type: "Organization", scope_id: other_organization_id)
      CapabilityGrant.create!(user_id: user_id, permission: "do.some.mcguffin", scope_type: "Account", scope_id: SecureRandom.uuid)

      get "/capabilities/Organization/#{organization_id}", headers: { "pad-user-id" => user_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(["msp.admin.users", "organization.accounts.read"])
    end
  end

  describe "GET /capabilities/Account/:account_id" do
    it "returns non-MSP account capabilities from the full parent chain" do
      root_account_id = SecureRandom.uuid
      parent_account_id = SecureRandom.uuid
      target_account_id = SecureRandom.uuid
      other_account_id = SecureRandom.uuid

      CapabilityGrant.create!(user_id: user_id, permission: "account.read", scope_type: "Account", scope_id: root_account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.users.read", scope_type: "Account", scope_id: parent_account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "do.some.mcguffin", scope_type: "Account", scope_id: target_account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "msp.admin.users", scope_type: "Account", scope_id: root_account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.users.create", scope_type: "Account", scope_id: other_account_id)

      allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
      allow(Account).to receive(:with_parents_batch).with([target_account_id]).and_return(
        [
          [
            OpenStruct.new(id: root_account_id),
            OpenStruct.new(id: parent_account_id),
            OpenStruct.new(id: target_account_id)
          ]
        ]
      )

      get "/capabilities/Account/#{target_account_id}", headers: { "pad-user-id" => user_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(["account.read", "account.users.read", "do.some.mcguffin"])
    end
  end

  it "does not support System capability context" do
    get "/capabilities/System/#{SecureRandom.uuid}", headers: { "pad-user-id" => user_id }

    expect(response).to have_http_status(:not_found)
  end
end
