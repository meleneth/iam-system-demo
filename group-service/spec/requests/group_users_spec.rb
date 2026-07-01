require "rails_helper"

RSpec.describe "/group_users", type: :request do
  let(:actor_user_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:user_id) { SecureRandom.uuid }
  let!(:group) { Group.create!(account_id: account_id, name: "Engineering") }
  let!(:group_user) { GroupUser.create!(group_id: group.id, user_id: user_id) }

  describe "read authorization" do
    it "checks account.users.read for an individual membership through the owning group" do
      expect(User).to receive(:user_can)
        .with(actor_user_id, "Account", "account.users.read", [account_id])
        .and_return(true)

      get group_user_url(group_user), headers: { "pad-user-id" => actor_user_id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("id" => group_user.id, "group_id" => group.id, "user_id" => user_id)
    end

    it "checks account.users.read over distinct owning group account IDs" do
      other_account_id = SecureRandom.uuid
      other_group = Group.create!(account_id: other_account_id, name: "Support")
      other_group_user = GroupUser.create!(group_id: other_group.id, user_id: SecureRandom.uuid)

      expect(User).to receive(:user_can)
        .with(actor_user_id, "Account", "account.users.read", match_array([account_id, other_account_id]))
        .and_return(true)

      post "/group_users/search",
           params: { id: [group_user.id, other_group_user.id] },
           headers: { "pad-user-id" => actor_user_id },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.length).to eq(2)
    end

    it "allows IAM_SYSTEM to read without actor grants" do
      expect(User).not_to receive(:user_can)

      get group_user_url(group_user), headers: { "pad-user-id" => "IAM_SYSTEM" }, as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
