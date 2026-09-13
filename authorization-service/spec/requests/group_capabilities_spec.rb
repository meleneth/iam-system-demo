require "rails_helper"
require "ostruct"

RSpec.describe "Group scope authorization", type: :request do
  it "keeps single, batch and /can group decisions equal for exact and inherited grants" do
    actor, member_group, target, sibling, account = Array.new(5) { SecureRandom.uuid }
    CapabilityGrant.create!(group_id: member_group, permission: "group.read", scope_type: "Group", scope_id: target)
    stub_const("AUTHORIZATION_CACHE", IamDemo::NullRedisCache.new)
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for).with(actor).and_return([member_group])
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:groups) do |_client, ids|
      ids.map { |id| {"id" => id, "account_id" => account} }
    end
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).and_return({"accounts" => []})
    allow(Account).to receive(:with_headers).and_yield
    allow(Account).to receive(:with_parents_batch).and_return([[OpenStruct.new(id: account, parent_account_id: nil)]])
    headers = {"pad-user-id" => actor}
    get "/capabilities/Group/#{target}", headers: headers
    expect(response.parsed_body).to eq(["group.read"])
    post "/capabilities/Group", params: {scope_id: [target, sibling]}, headers: headers, as: :json
    expect(response.parsed_body).to eq(target => ["group.read"], sibling => [])
    post "/can/Group/group.read", params: {scope_id: [target]}, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    post "/can/Group/group.read", params: {scope_id: [target, sibling]}, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    CapabilityGrant.create!(group_id: member_group, permission: "group.read", scope_type: "Account", scope_id: account)
    post "/can/Group/group.read", params: {scope_id: [target, sibling]}, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end
end
