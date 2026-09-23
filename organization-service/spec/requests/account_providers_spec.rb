require "rails_helper"

RSpec.describe "Authorization provider contexts", type: :request do
  let(:headers) { {"pad-user-id" => "IAM_SYSTEM_AUTH"} }

  around { |example| AuthorizationContext.as_iam { example.run } }

  it "links every client account through its organization, with no client account ownership edge" do
    provider_org, client_org, unrelated_org = Array.new(3) { Organization.create! }
    provider, root, child, unrelated = Array.new(4) { SecureRandom.uuid }
    OrganizationAccount.create!(organization: provider_org, account_id: provider)
    [root, child].each { |id| OrganizationAccount.create!(organization: client_org, account_id: id) }
    OrganizationAccount.create!(organization: unrelated_org, account_id: unrelated)
    MspManagedOrganization.create!(msp_organization_id: provider_org.id, msp_account_id: provider, client_organization_id: client_org.id)
    post "/internal/auth/account_providers", params: {account_ids: [root, child, unrelated]}, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("accounts")).to match_array([root, child].map do |target|
      {"account_id" => target, "msp_account_id" => provider, "msp_organization_id" => provider_org.id, "client_organization_id" => client_org.id}
    end)
    OrganizationAccount.where(account_id: provider).delete_all
    post "/internal/auth/account_providers", params: {account_ids: [root, child]}, headers: headers, as: :json
    expect(response.parsed_body).to eq("accounts" => [])
  end

  it "rejects ordinary callers and the general system identity" do
    [SecureRandom.uuid, "IAM_SYSTEM", nil].each do |actor|
      post "/internal/auth/account_providers", params: {account_ids: []}, headers: actor ? {"pad-user-id" => actor} : {}, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
