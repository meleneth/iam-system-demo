require "rails_helper"

RSpec.describe "Group counts", type: :request do
  it "checks explicit account targets and preserves denial" do
    account_id = SecureRandom.uuid
    client = instance_double(AuthorizedResource::AuthorizationClient)
    allow(AuthorizedResource).to receive(:authorization_client).and_return(client)
    expect(client).to receive(:capabilities).ordered.and_return(
      "Account" => { account_id => ["account.users.read"] }
    )
    expect(client).to receive(:capabilities).ordered.and_return(
      "Account" => { account_id => [] }
    )

    statuses = 2.times.map do
      post "/accounts/groups/counts", params: { account_id: [account_id] },
           headers: { "pad-user-id" => "actor" }, as: :json
      response.status
    end
    expect(statuses).to eq([200, 403])
  end
end
