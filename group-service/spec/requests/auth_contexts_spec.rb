require "rails_helper"

RSpec.describe "Authorization group contexts", type: :request do
  let(:actor) { SecureRandom.uuid }
  let(:headers) { {"pad-user-id" => "IAM_SYSTEM_AUTH"} }
  let!(:group) { Group.create!(account_id: SecureRandom.uuid, name: "Readers") }

  it "returns explicit memberships only, deduplicated and excluding dangling groups" do
    2.times { GroupUser.create!(group_id: group.id, user_id: actor) }
    GroupUser.create!(group_id: SecureRandom.uuid, user_id: actor)
    GroupUser.create!(group_id: group.id, user_id: SecureRandom.uuid)
    post "/internal/auth/memberships", params: {user_id: actor}, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("memberships" => [{"group_id" => group.id, "user_id" => actor}])
  end

  it "returns the group's owning account from group-service data" do
    post "/internal/auth/group_contexts", params: {group_ids: [group.id, SecureRandom.uuid]}, headers: headers, as: :json
    expect(response.parsed_body).to eq("groups" => [{"id" => group.id, "account_id" => group.account_id}])
  end

  it "rejects ordinary actors and the general system identity on the narrow auth endpoint" do
    [actor, "IAM_SYSTEM", nil].each do |identity|
      post "/internal/auth/memberships", params: {user_id: actor}, headers: identity ? {"pad-user-id" => identity} : {}, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "does not make IAM_SYSTEM_AUTH a general resource bypass" do
    allow(User).to receive(:user_can).and_return(false)
    get "/groups/#{group.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
