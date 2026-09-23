require "rails_helper"

RSpec.describe "/groups", type: :request do
  let(:actor_user_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let!(:group) { Group.create!(account_id: account_id, name: "Engineering") }
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  def capabilities_for(values)
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)
    expect(authorization_client).to receive(:capabilities).once.and_return(values)
  end

  it "checks the owning account capability for an individual group" do
    capabilities_for(
      "Group" => { group.id => [] },
      "Account" => { account_id => ["account.users.read"] }
    )
    get group_url(group), headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => group.id, "account_id" => account_id)
  end

  it "batches mixed account and exact-group alternatives without cross-record leakage" do
    other = Group.create!(account_id: SecureRandom.uuid, name: "External")
    capabilities_for(
      "Group" => { group.id => [], other.id => ["group.read"] },
      "Account" => { account_id => ["account.users.read"], other.account_id => [] }
    )
    post "/groups/search", params: { id: [group.id, other.id] },
         headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |row| row.fetch("id") }).to match_array([group.id, other.id])
  end

  it "denies a collection when any returned group has no valid alternative" do
    other = Group.create!(account_id: SecureRandom.uuid, name: "External")
    capabilities_for(
      "Group" => { group.id => [], other.id => [] },
      "Account" => { account_id => ["account.users.read"], other.account_id => [] }
    )
    post "/groups/search", params: { id: [group.id, other.id] },
         headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "authorizes count aggregates against explicit account targets" do
    capabilities_for("Account" => { account_id => ["account.users.read"] })
    get "/accounts/groups/counts", params: { account_id: [account_id] },
        headers: { "pad-user-id" => actor_user_id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(account_id => 1)
  end

  it "allows configured IAM_SYSTEM reads without capability transport" do
    expect(AuthorizedModel).not_to receive(:authorization_client)
    get group_url(group), headers: {
      "pad-user-id" => "IAM_SYSTEM",
    }, as: :json
    expect(response).to have_http_status(:ok)
  end
end
