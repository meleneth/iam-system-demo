require "rails_helper"
require "securerandom"

RSpec.describe "internal auth account contexts", type: :request do
  let(:msp_organization_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }
  let(:other_msp_account_id) { SecureRandom.uuid }
  let(:client_organization_id) { SecureRandom.uuid }
  let(:other_organization_id) { SecureRandom.uuid }
  let(:target_account_id) { SecureRandom.uuid }
  let(:client_parent_account_id) { SecureRandom.uuid }
  let(:outside_parent_account_id) { SecureRandom.uuid }

  it "returns managed account contexts and constrains parent IDs to the client organization" do
    create_valid_relationship!
    OrganizationAccount.create!(organization_id: client_organization_id, account_id: target_account_id)
    OrganizationAccount.create!(organization_id: client_organization_id, account_id: client_parent_account_id)
    OrganizationAccount.create!(organization_id: other_organization_id, account_id: outside_parent_account_id)

    post "/internal/auth/account_contexts",
         params: {
           contexts: [
             {
               msp_organization_id: msp_organization_id,
               msp_account_id: msp_account_id,
               accounts: [
                 {
                   account_id: target_account_id,
                   parent_account_ids: [client_parent_account_id, outside_parent_account_id]
                 }
               ]
             }
           ]
         },
         headers: { "pad-user-id" => "IAM_SYSTEM_AUTH" },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("accounts")).to contain_exactly(
      {
        "msp_organization_id" => msp_organization_id,
        "msp_account_id" => msp_account_id,
        "client_organization_id" => client_organization_id,
        "account_id" => target_account_id,
        "parent_account_ids" => [client_parent_account_id]
      }
    )
  end

  it "omits accounts outside the provided MSP organization and account context" do
    create_valid_relationship!
    OrganizationAccount.create!(organization_id: client_organization_id, account_id: target_account_id)

    post "/internal/auth/account_contexts",
         params: {
           contexts: [
             {
               msp_organization_id: msp_organization_id,
               msp_account_id: other_msp_account_id,
               accounts: [{ account_id: target_account_id, parent_account_ids: [] }]
             }
           ]
         },
         headers: { "pad-user-id" => "IAM_SYSTEM_AUTH" },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("accounts")).to be_empty
  end

  it "rejects non-auth-system callers" do
    post "/internal/auth/account_contexts",
         params: { contexts: [] },
         headers: { "pad-user-id" => "IAM_SYSTEM" },
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "IAM_SYSTEM_AUTH required")
  end

  def create_valid_relationship!
    Organization.create!(id: msp_organization_id)
    Organization.create!(id: client_organization_id)
    Organization.create!(id: other_organization_id)
    OrganizationAccount.create!(organization_id: msp_organization_id, account_id: msp_account_id)
    MspManagedOrganization.create!(
      msp_organization_id: msp_organization_id,
      msp_account_id: msp_account_id,
      client_organization_id: client_organization_id
    )
  end
end
