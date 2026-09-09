require "rails_helper"

RSpec.describe "Group counts", type: :request do
  it "accepts JSON batches while checking the real actor" do
    account_id = SecureRandom.uuid
    expect(User).to receive(:user_can).with("actor", "Account", "account.users.read", [account_id]).and_return(true)
    post "/accounts/groups/counts", params: { account_id: [account_id] }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(account_id => 0)
  end
end
