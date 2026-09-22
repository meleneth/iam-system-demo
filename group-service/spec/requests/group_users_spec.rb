require "rails_helper"

RSpec.describe "/group_users", type: :request do
  let(:actor_user_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:user_id) { SecureRandom.uuid }
  let!(:group) { Group.create!(account_id: account_id, name: "Engineering") }
  let!(:group_user) { GroupUser.create!(group_id: group.id, user_id: user_id) }
  let(:authorization_client) { instance_double(AuthorizedResource::AuthorizationClient) }

  def allow_group_capabilities(map)
    allow(AuthorizedResource).to receive(:authorization_client).and_return(authorization_client)
    expect(authorization_client).to receive(:capabilities).once.and_return("Group" => map)
  end

  it "checks group capabilities, including inherited account capabilities" do
    allow_group_capabilities(group.id => ["account.users.read"])
    get group_user_url(group_user), headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("group_id" => group.id, "user_id" => user_id)
  end

  it "batches distinct owning groups and denies a mixed unauthorized result" do
    other = Group.create!(account_id: SecureRandom.uuid, name: "Support")
    membership = GroupUser.create!(group_id: other.id, user_id: SecureRandom.uuid)
    allow_group_capabilities(group.id => ["group.read"], other.id => [])
    post "/group_users/search", params: { id: [group_user.id, membership.id] },
         headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "allows IAM_SYSTEM without capability transport" do
    expect(AuthorizedResource).not_to receive(:authorization_client)
    get group_user_url(group_user), headers: {
      "pad-user-id" => "IAM_SYSTEM",
      "X-IAM-Authorization-Scope" => "iam",
      "X-IAM-Internal-Token" => ENV.fetch("IAM_INTERNAL_TOKEN")
    }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "fails closed when a membership has no owning group capability" do
    orphan = GroupUser.create!(group_id: SecureRandom.uuid, user_id: SecureRandom.uuid)
    allow_group_capabilities(group.id => ["group.read"], orphan.group_id => [])
    post "/group_users/search", params: { id: [group_user.id, orphan.id] },
         headers: { "pad-user-id" => actor_user_id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
