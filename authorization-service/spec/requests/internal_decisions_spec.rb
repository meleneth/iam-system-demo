require "rails_helper"
require "set"

RSpec.describe "Internal authorization decisions", type: :request do
  let(:actor_id) { SecureRandom.uuid }
  let(:organization_id) { SecureRandom.uuid }
  let(:other_organization_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:other_account_id) { SecureRandom.uuid }
  let(:capabilities) { instance_double(Authorization::Capabilities) }

  before do
    allow(Authorization::Capabilities).to receive(:new).with(user_id: actor_id).and_return(capabilities)
  end

  it "returns correlated decisions for the two relationship-policy questions" do
    expect(capabilities).to receive(:organization_ids_with_permission)
      .with([organization_id, other_organization_id], "organization.read.accounts")
      .and_return(Set[organization_id])
    expect(capabilities).to receive(:account_ids_with_permission)
      .with([account_id, other_account_id], "account.read")
      .and_return(Set[other_account_id])

    post "/internal/decisions",
         params: {targets: [
           {scope_type: "Organization", scope_id: organization_id, permission: "organization.read.accounts"},
           {scope_type: "Account", scope_id: account_id, permission: "account.read"},
           {scope_type: "Organization", scope_id: other_organization_id, permission: "organization.read.accounts"},
           {scope_type: "Account", scope_id: other_account_id, permission: "account.read"}
         ]},
         headers: {"pad-user-id" => actor_id},
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("decisions").map { |row| row.fetch("allowed") })
      .to eq([true, false, false, true])
  end

  it "rejects missing, IAM, empty, and unsupported questions" do
    expect(Authorization::Capabilities).not_to receive(:new)

    post "/internal/decisions", params: {targets: [
      {scope_type: "Account", scope_id: account_id, permission: "account.read"}
    ]}, as: :json
    expect(response).to have_http_status(:forbidden)

    post "/internal/decisions", params: {targets: [
      {scope_type: "Account", scope_id: account_id, permission: "account.read"}
    ]}, headers: {"pad-user-id" => "IAM_SYSTEM"}, as: :json
    expect(response).to have_http_status(:forbidden)

    post "/internal/decisions", params: {targets: []}, headers: {"pad-user-id" => actor_id}, as: :json
    expect(response).to have_http_status(:bad_request)

    post "/internal/decisions", params: {targets: [
      {scope_type: "Account", scope_id: account_id, permission: "account.delete"}
    ]}, headers: {"pad-user-id" => actor_id}, as: :json
    expect(response).to have_http_status(:bad_request)
  end
end
