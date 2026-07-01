require "rails_helper"
require "securerandom"

RSpec.describe "internal MSP managed organizations", type: :request do
  let(:msp_organization_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }
  let(:client_organization_id) { SecureRandom.uuid }
  let(:account_1_id) { SecureRandom.uuid }
  let(:account_2_id) { SecureRandom.uuid }

  it "returns paginated account IDs managed by an MSP account" do
    create_valid_relationship!
    OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_2_id)
    OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_1_id)

    get "/internal/msp_managed_organizations/#{msp_account_id}",
        params: { limit: 1 },
        headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    first_page = response.parsed_body
    expect(first_page.fetch("msp_organization_id")).to eq(msp_organization_id)
    expect(first_page.fetch("msp_account_id")).to eq(msp_account_id)
    expect(first_page.fetch("managed_account_ids").length).to eq(1)
    expect(first_page.fetch("total_count")).to eq(2)
    expect(first_page.fetch("continuance")).to be_present

    get "/internal/msp_managed_organizations/#{msp_account_id}",
        params: { continuance: first_page.fetch("continuance"), limit: 1 },
        headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    second_page = response.parsed_body
    expect(first_page.fetch("managed_account_ids") + second_page.fetch("managed_account_ids")).to match_array([account_1_id, account_2_id])
    expect(second_page.fetch("continuance")).to be_nil
  end

  it "rejects non-system callers" do
    get "/internal/msp_managed_organizations/#{msp_account_id}",
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "IAM_SYSTEM required")
  end

  def create_valid_relationship!
    Organization.create!(id: msp_organization_id)
    Organization.create!(id: client_organization_id)
    OrganizationAccount.create!(organization_id: msp_organization_id, account_id: msp_account_id)
    MspManagedOrganization.create!(
      msp_organization_id: msp_organization_id,
      msp_account_id: msp_account_id,
      client_organization_id: client_organization_id
    )
  end
end
