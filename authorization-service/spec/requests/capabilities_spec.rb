require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe "Capabilities", type: :request do
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

  let(:user_id) { SecureRandom.uuid }

  before do
    stub_const("AUTHORIZATION_CACHE", IamDemo::NullRedisCache.new)
  end

  describe "GET /capabilities/Organization/:organization_id" do
    it "returns direct organization-scoped capability names" do
      organization_id = SecureRandom.uuid
      other_organization_id = SecureRandom.uuid
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.read.accounts", scope_type: "Organization", scope_id: organization_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.users.manage", scope_type: "Organization", scope_id: organization_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.read", scope_type: "Organization", scope_id: other_organization_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "do.some.mcguffin", scope_type: "Account", scope_id: SecureRandom.uuid)

      get "/capabilities/Organization/#{organization_id}", headers: { "pad-user-id" => user_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(["organization.read.accounts", "organization.users.manage"])
    end
  end

  describe "GET /capabilities/Account/:account_id" do
    it "returns account capabilities from the full parent chain" do
      root_account_id = SecureRandom.uuid
      parent_account_id = SecureRandom.uuid
      target_account_id = SecureRandom.uuid
      other_account_id = SecureRandom.uuid

      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: root_account_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.users.read", scope_type: "Account", scope_id: parent_account_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "do.some.mcguffin", scope_type: "Account", scope_id: target_account_id)
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.users.create", scope_type: "Account", scope_id: other_account_id)

      allow(Account).to receive(:with_parents_batch).with([target_account_id]).and_return(
        [
          [
            OpenStruct.new(id: root_account_id, parent_account_id: nil),
            OpenStruct.new(id: parent_account_id, parent_account_id: root_account_id),
            OpenStruct.new(id: target_account_id, parent_account_id: parent_account_id)
          ]
        ]
      )

      get "/capabilities/Account/#{target_account_id}", headers: { "pad-user-id" => user_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(["account.read", "account.users.read", "do.some.mcguffin"])
    end
  end

  describe "POST /capabilities/Account" do
    it "returns capabilities keyed by requested account ID" do
      account_id = SecureRandom.uuid
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "account.read", scope_type: "Account", scope_id: account_id)
      allow(Account).to receive(:with_parents_batch).with([account_id]).and_return(
        [[OpenStruct.new(id: account_id)]]
      )

      post "/capabilities/Account",
           params: { scope_id: [account_id] },
           headers: { "pad-user-id" => user_id },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(account_id => ["account.read"])
    end
  end

  describe "POST /capabilities/Organization" do
    it "returns capabilities keyed by requested organization ID" do
      organization_id = SecureRandom.uuid
      CapabilityGrant.create!(group_id: grant_group_id(user_id), permission: "organization.read", scope_type: "Organization", scope_id: organization_id)

      post "/capabilities/Organization",
           params: { scope_id: [organization_id] },
           headers: { "pad-user-id" => user_id },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(organization_id => ["organization.read"])
    end
  end

  it "does not support System capability context" do
    get "/capabilities/System/#{SecureRandom.uuid}", headers: { "pad-user-id" => user_id }

    expect(response).to have_http_status(:not_found)
  end
end
