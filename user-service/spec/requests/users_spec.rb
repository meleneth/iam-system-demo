require "rails_helper"

RSpec.describe "/users", type: :request do
  let(:account_id) { SecureRandom.uuid }
  let(:valid_attributes) { { account_id: account_id, email: "foo@example.com" } }
  let(:iam_headers) do
    {
      "pad-user-id" => "IAM_SYSTEM",
    }
  end
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  def capabilities_for(map)
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)
    expect(authorization_client).to receive(:capabilities).once.and_return("Account" => map)
  end

  it "supports IAM collection and single-record retrievals" do
    user = User.create!(valid_attributes)
    get "/users", params: { account_id: account_id }, headers: iam_headers
    expect(response).to be_successful
    get user_url(user), headers: iam_headers, as: :json
    expect(response).to be_successful
  end

  it "checks account.users.read for individual users" do
    user = User.create!(valid_attributes)
    capabilities_for(account_id => ["account.users.read"])
    get user_url(user), headers: { "pad-user-id" => "reader-user" }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "checks one batched decision for collection account IDs" do
    User.create!(valid_attributes)
    capabilities_for(account_id => ["account.users.read"])
    post "/users/search", params: { account_id: [account_id] },
         headers: { "pad-user-id" => "reader-user" }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "ignores stale MSP headers and preserves the requesting actor" do
    User.create!(valid_attributes)
    capabilities_for(account_id => ["account.users.read"])
    post "/users/search", params: { account_id: [account_id] },
         headers: { "pad-user-id" => "msp-admin", "pad-msp-account-id" => "stale" }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "returns forbidden when the account capability is absent" do
    user = User.create!(valid_attributes)
    capabilities_for(account_id => [])
    get user_url(user), headers: { "pad-user-id" => "reader-user" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "checks explicit targets before aggregate counts" do
    User.create!(valid_attributes)
    capabilities_for(account_id => ["account.users.read"])
    get "/accounts/users/counts", params: { account_id: [account_id] },
        headers: { "pad-user-id" => "reader-user" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(account_id => 1)
  end
end
