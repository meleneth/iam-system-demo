require "rails_helper"
require "securerandom"

RSpec.describe "internal MSP managed accounts", type: :request do
  let(:msp_account_id) { SecureRandom.uuid }
  let(:managed_account_ids) { Array.new(3) { SecureRandom.uuid } }

  it "returns directional managed account IDs in pages" do
    managed_account_ids.each do |managed_account_id|
      MspManagedAccount.create!(msp_account_id: msp_account_id, managed_account_id: managed_account_id)
    end

    get "/internal/msp_managed_accounts/#{msp_account_id}", params: { limit: 2, offset: 0 }, headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.fetch("total_count")).to eq(3)
    expect(body.fetch("managed_account_ids").length).to eq(2)
  end

  it "does not imply normal organization membership or a reciprocal mapping" do
    managed_account_id = managed_account_ids.first
    MspManagedAccount.create!(msp_account_id: msp_account_id, managed_account_id: managed_account_id)

    expect(OrganizationAccount.where(organization_id: msp_account_id, account_id: managed_account_id)).not_to exist
    expect(MspManagedAccount.where(msp_account_id: managed_account_id, managed_account_id: msp_account_id)).not_to exist

    get "/internal/msp_managed_accounts/#{managed_account_id}/#{msp_account_id}", headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch("managed")).to eq(false)
  end

  it "deduplicates mappings by MSP and managed account" do
    managed_account_id = managed_account_ids.first

    MspManagedAccount.create!(msp_account_id: msp_account_id, managed_account_id: managed_account_id)

    expect {
      MspManagedAccount.find_or_create_by!(msp_account_id: msp_account_id, managed_account_id: managed_account_id)
    }.not_to change(MspManagedAccount, :count)
  end
end
