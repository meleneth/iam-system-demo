require "rails_helper"

RSpec.describe "/groups", type: :request do
  FakeFaradayResponse = Struct.new(:status, :body)
  FakeFaradayRequest = Struct.new(:headers, :body, keyword_init: true)

  let(:actor_user_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }

  describe "read authorization" do
    let!(:group) { Group.create!(account_id: account_id, name: "Engineering") }

    it "checks account.users.read for an individual group" do
      expect(User).to receive(:user_can)
        .with(actor_user_id, "Account", "account.users.read", [account_id])
        .and_return(true)

      get group_url(group), headers: { "pad-user-id" => actor_user_id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("id" => group.id, "account_id" => account_id)
    end

    it "checks account.users.read over distinct returned group account IDs" do
      other_account_id = SecureRandom.uuid
      Group.create!(account_id: account_id, name: "Support")
      Group.create!(account_id: other_account_id, name: "Sales")

      expect(User).to receive(:user_can)
        .with(actor_user_id, "Account", "account.users.read", match_array([account_id, other_account_id]))
        .and_return(true)

      group_ids = AuthorizationContext.as_iam { Group.where(account_id: [account_id, other_account_id]).pluck(:id) }
      post "/groups/search",
           params: { id: group_ids },
           headers: { "pad-user-id" => actor_user_id },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.length).to eq(3)
    end

    it "preserves individual allows when a batch mixes account authority and exact-group authority" do
      other = Group.create!(account_id: SecureRandom.uuid, name: "External")
      allow(User).to receive(:user_can) do |actor, scope, permission, ids|
        (scope == "Account" && permission == "account.users.read" && ids == [account_id]) ||
          (scope == "Group" && permission == "group.read" && ids == [other.id])
      end
      [group, other].each do |target|
        get group_url(target), headers: {"pad-user-id" => actor_user_id}, as: :json
        expect(response).to have_http_status(:ok)
      end
      post "/groups/search", params: {id: [group.id, other.id]}, headers: {"pad-user-id" => actor_user_id}, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |row| row.fetch("id") }).to match_array([group.id, other.id])
    end

    it "requires account.users.read before returning group counts" do
      expect(User).to receive(:user_can)
        .with(actor_user_id, "Account", "account.users.read", [account_id])
        .and_return(true)

      get "/accounts/groups/counts",
          params: { account_id: [account_id] },
          headers: { "pad-user-id" => actor_user_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(account_id => 1)
    end

    it "allows IAM_SYSTEM to read without actor grants" do
      expect(User).not_to receive(:user_can)

      get group_url(group), headers: { "pad-user-id" => "IAM_SYSTEM", "X-IAM-Authorization-Scope" => "iam", "X-IAM-Internal-Token" => ENV.fetch("IAM_INTERNAL_TOKEN") }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "capabilities-only authorization mode" do
    it "checks batched account capabilities instead of calling /can" do
      account_ids = [SecureRandom.uuid, SecureRandom.uuid]
      request = nil
      old_mode = ENV["AUTHORIZATION_CHECK_MODE"]
      ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"

      expect(Faraday).to receive(:post).with("#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/Account") do |&block|
        request = FakeFaradayRequest.new(headers: {})
        block.call(request)
        FakeFaradayResponse.new(
          200,
          account_ids.to_h { |account_id| [account_id, ["account.users.read"]] }.to_json
        )
      end

      allowed = AuthorizationContext.as_requesting_user(user_id: actor_user_id) do
        User.user_can(actor_user_id, "Account", "account.users.read", account_ids)
      end
      expect(allowed).to eq(true)
      expect(JSON.parse(request.body)).to eq("scope_id" => account_ids)
    ensure
      ENV["AUTHORIZATION_CHECK_MODE"] = old_mode
    end
  end
end
