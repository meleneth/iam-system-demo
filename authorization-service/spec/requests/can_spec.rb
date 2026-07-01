require 'rails_helper'
require 'ostruct'

RSpec.describe "Cans", type: :request do
  class DisabledAuthorizationCache
    def redis_enabled?
      false
    end
  end

  describe "POST /can/Account/:permission" do
    let(:user_id) { SecureRandom.uuid }
    let(:msp_account_id) { SecureRandom.uuid }
    let(:customer_account_id) { SecureRandom.uuid }
    let(:other_customer_account_id) { SecureRandom.uuid }
    let(:parent_account_id) { SecureRandom.uuid }
    let(:headers) do
      {
        "pad-user-id" => user_id,
        "pad-msp-account-id" => msp_account_id
      }
    end

    before do
      stub_const("AUTHORIZATION_CACHE", DisabledAuthorizationCache.new)
    end

    it "uses native account hierarchy grants when stale MSP headers are present" do
      CapabilityGrant.create!(
        user_id: user_id,
        permission: "account.users.read",
        scope_type: "Account",
        scope_id: parent_account_id
      )
      allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
      allow(Account).to receive(:with_parents_batch).with([customer_account_id]).and_return(
        [[
          OpenStruct.new(id: parent_account_id),
          OpenStruct.new(id: customer_account_id)
        ]]
      )

      post "/can/Account/account.users.read",
           params: { scope_id: [customer_account_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it "does not authorize stale MSP headers without native account grants" do
      allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
      allow(Account).to receive(:with_parents_batch).with([customer_account_id]).and_return(
        [[OpenStruct.new(id: customer_account_id)]]
      )

      post "/can/Account/account.users.read",
           params: { scope_id: [customer_account_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "requires the permission on every requested account scope" do
      CapabilityGrant.create!(
        user_id: user_id,
        permission: "account.users.read",
        scope_type: "Account",
        scope_id: customer_account_id
      )
      requested_account_ids = [customer_account_id, other_customer_account_id]
      allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
      allow(Account).to receive(:with_parents_batch).with(requested_account_ids).and_return(
        [
          [OpenStruct.new(id: customer_account_id)],
          [OpenStruct.new(id: other_customer_account_id)]
        ]
      )

      post "/can/Account/account.users.read",
           params: { scope_id: requested_account_ids },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects /can when capabilities-only authorization mode is enabled" do
      old_mode = ENV["AUTHORIZATION_CHECK_MODE"]
      ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"
      post "/can/Account/account.users.read",
           params: { scope_id: [customer_account_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("error" => "/can disabled by AUTHORIZATION_CHECK_MODE=capabilities")
    ensure
      ENV["AUTHORIZATION_CHECK_MODE"] = old_mode
    end
  end

  describe "POST /can/System/:permission" do
    it "rejects system scope because no system capabilities are defined" do
      post "/can/System/system.admin",
           headers: { "pad-user-id" => SecureRandom.uuid },
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("error" => "Invalid scope_type")
    end
  end
end
