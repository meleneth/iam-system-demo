require "rails_helper"

RSpec.describe "User counts", type: :request do
  it "accepts JSON batches with the real actor and preserves authorization denial" do
    account_id = SecureRandom.uuid
    allow(User).to receive(:user_can?).with(user_id: "actor", permission: "account.users.read", account_ids: [account_id]).and_return(true, false)
    post "/accounts/users/counts", params: { account_id: [account_id] }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(account_id => 0)
    post "/accounts/users/counts", params: { account_id: [account_id] }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
