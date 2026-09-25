require "rails_helper"
require "securerandom"

RSpec.describe "internal MSP managed organizations", type: :request do
  let(:msp_organization_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }
  let(:client_organization_id) { SecureRandom.uuid }
  let(:account_1_id) { SecureRandom.uuid }
  let(:account_2_id) { SecureRandom.uuid }
  let(:account_3_id) { SecureRandom.uuid }

  it "returns paginated account IDs managed by an MSP account" do
    create_valid_relationship!
    AuthorizationContext.as_iam do
      OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_2_id)
      OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_1_id)
    end

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

  it "uses IAM_DEMO_BATCH_SIZE as the default and maximum page size" do
    old_batch_size = ENV["IAM_DEMO_BATCH_SIZE"]
    ENV["IAM_DEMO_BATCH_SIZE"] = "2"

    create_valid_relationship!
    AuthorizationContext.as_iam do
      [account_1_id, account_2_id, account_3_id].each do |account_id|
        OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_id)
      end
    end

    get "/internal/msp_managed_organizations/#{msp_account_id}",
        params: { limit: 100 },
        headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page.fetch("managed_account_ids").length).to eq(2)
    expect(page.fetch("total_count")).to eq(3)
    expect(page.fetch("continuance")).to eq("2")
  ensure
    ENV["IAM_DEMO_BATCH_SIZE"] = old_batch_size
  end

  it "records that an authorized one-row page materializes every managed relationship" do
    create_valid_relationship!
    account_ids = Array.new(7) { SecureRandom.uuid }
    AuthorizationContext.as_iam do
      account_ids.each do |account_id|
        OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_id)
      end
    end

    target_batch_sizes = []
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    allow(authorization_client).to receive(:capabilities) do |targets|
      target_batch_sizes << targets.size
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h { |target| [target.scope_id, [target.capability]] }
      end
    end
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)

    get "/msp_managed_organizations/#{msp_account_id}",
        params: { limit: 1 },
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("managed_account_ids").size).to eq(1)
    expect(response.parsed_body.fetch("total_count")).to eq(account_ids.size)
    expect(target_batch_sizes).to include(account_ids.size)
  end

  it "rejects non-system callers" do
    get "/internal/msp_managed_organizations/#{msp_account_id}",
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "IAM_SYSTEM required")
  end

  def create_valid_relationship!
    AuthorizationContext.as_iam do
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
end
