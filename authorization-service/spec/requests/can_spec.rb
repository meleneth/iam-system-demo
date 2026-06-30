require 'rails_helper'

RSpec.describe "Cans", type: :request do
  describe "POST /can/Account/:permission" do
    let(:user_id) { SecureRandom.uuid }
    let(:msp_account_id) { SecureRandom.uuid }
    let(:customer_account_id) { SecureRandom.uuid }
    let(:headers) do
      {
        "pad-user-id" => user_id,
        "pad-msp-account-id" => msp_account_id
      }
    end

    it "authorizes MSP reflected user-management grants without loading native account hierarchy" do
      reflected = instance_double(Authorization::MspReflectedUserGrants)
      allow(Authorization::MspReflectedUserGrants).to receive(:new).and_return(reflected)
      expect(reflected).to receive(:check).with(
        user_id: user_id,
        msp_account_id: msp_account_id,
        account_ids: [customer_account_id]
      ).and_return(
        status: "ready",
        loading: false,
        loaded_count: 1,
        total_count: 1,
        authorized_account_ids: [customer_account_id]
      )
      expect(Account).not_to receive(:with_headers)

      post "/can/Account/account.users.read",
           params: { scope_id: [customer_account_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns loading progress for MSP reflected grants without loading native account hierarchy" do
      reflected = instance_double(Authorization::MspReflectedUserGrants)
      allow(Authorization::MspReflectedUserGrants).to receive(:new).and_return(reflected)
      expect(reflected).to receive(:check).and_return(
        status: "loading",
        loading: true,
        loaded_count: 250,
        total_count: 1000,
        authorized_account_ids: []
      )
      expect(Account).not_to receive(:with_headers)

      post "/can/Account/account.users.read",
           params: { scope_id: [customer_account_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include(
        "loading" => true,
        "loaded_count" => 250,
        "total_count" => 1000
      )
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
