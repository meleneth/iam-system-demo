require "rails_helper"

RSpec.describe "User counts", type: :request do
  it "preserves authorization denial for aggregate targets" do
    account_id = SecureRandom.uuid
    client = instance_double(AuthorizedResource::AuthorizationClient)
    allow(AuthorizedResource).to receive(:authorization_client).and_return(client)
    expect(client).to receive(:capabilities).ordered.and_return(
      "Account" => { account_id => ["account.users.read"] }
    )
    expect(client).to receive(:capabilities).ordered.and_return(
      "Account" => { account_id => [] }
    )

    2.times do
      post "/accounts/users/counts", params: { account_id: [account_id] },
           headers: { "pad-user-id" => "actor" }, as: :json
      yield_status = response.status
      @statuses ||= []
      @statuses << yield_status
    end
    expect(@statuses).to eq([200, 403])
  end
end
