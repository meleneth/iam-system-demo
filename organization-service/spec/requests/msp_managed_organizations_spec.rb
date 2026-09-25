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

    get "/internal/msp_managed_organizations/#{msp_account_id}",
        params: { continuance: 2, limit: 1 },
        headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "managed_account_ids" => [],
      "total_count" => 2,
      "continuance" => nil
    )

    get "/internal/msp_managed_organizations/#{msp_account_id}",
        params: { continuance: 50, limit: 1 },
        headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "managed_account_ids" => [],
      "total_count" => 2,
      "continuance" => nil
    )
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

  it "counts the full relation but materializes and authorizes only the requested page" do
    create_valid_relationship!
    account_ids = Array.new(7) { SecureRandom.uuid }
    AuthorizationContext.as_iam do
      account_ids.each do |account_id|
        OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_id)
      end
    end

    authorization_batches = []
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    allow(authorization_client).to receive(:capabilities) do |targets|
      authorization_batches << targets
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h { |target| [target.scope_id, [target.capability]] }
      end
    end
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)

    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/msp_managed_organizations/#{msp_account_id}",
          params: { continuance: 2, limit: 1 },
          headers: { "pad-user-id" => SecureRandom.uuid }
    end

    expect(response).to have_http_status(:ok)
    expected_page_id = account_ids.sort.fetch(2)
    expect(response.parsed_body.fetch("managed_account_ids")).to eq([expected_page_id])
    expect(response.parsed_body.fetch("total_count")).to eq(account_ids.size)
    expect(response.parsed_body.fetch("continuance")).to eq("3")
    authorized_account_ids = authorization_batches.flatten.filter_map do |target|
      target.scope_id if target.scope_type == "Account"
    end
    expect(authorized_account_ids).to include(msp_account_id, expected_page_id)
    expect(authorized_account_ids - [msp_account_id, expected_page_id]).to be_empty
    page_query = sql.find do |statement|
      statement.include?('FROM "organization_accounts"') && statement.include?("LIMIT")
    end
    expect(page_query).to include("LIMIT", "OFFSET")
    expect(sql.grep(/SELECT DISTINCT "organization_accounts"\."account_id"/i)).to be_empty
  end

  it "rejects an unauthorized page account without authorizing off-page accounts" do
    create_valid_relationship!
    account_ids = Array.new(3) { SecureRandom.uuid }.sort
    AuthorizationContext.as_iam do
      account_ids.each do |account_id|
        OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_id)
      end
    end

    requested_ids = []
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    allow(authorization_client).to receive(:capabilities) do |targets|
      requested_ids.concat(targets.map(&:scope_id))
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h do |target|
          allowed = target.scope_id == msp_account_id
          [target.scope_id, allowed ? [target.capability] : []]
        end
      end
    end
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)

    get "/msp_managed_organizations/#{msp_account_id}",
        params: { limit: 1 },
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:forbidden)
    expect(requested_ids).to include(msp_account_id, account_ids.first)
    expect(requested_ids - [msp_account_id, account_ids.first]).to be_empty
  end

  it "rejects an unauthorized provider before reading managed page accounts" do
    create_valid_relationship!
    AuthorizationContext.as_iam do
      OrganizationAccount.create!(organization_id: client_organization_id, account_id: account_1_id)
    end

    requested_ids = []
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    allow(authorization_client).to receive(:capabilities) do |targets|
      requested_ids.concat(targets.map(&:scope_id))
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h { |target| [target.scope_id, []] }
      end
    end
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)

    get "/msp_managed_organizations/#{msp_account_id}",
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:forbidden)
    expect(requested_ids).to eq([msp_account_id])
  end

  it "returns an empty managed page with an authorized zero count" do
    create_valid_relationship!

    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    allow(authorization_client).to receive(:capabilities) do |targets|
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h { |target| [target.scope_id, [target.capability]] }
      end
    end
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)

    get "/msp_managed_organizations/#{msp_account_id}",
        headers: { "pad-user-id" => SecureRandom.uuid }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "managed_account_ids" => [],
      "total_count" => 0,
      "continuance" => nil
    )
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
