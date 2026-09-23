require "rails_helper"
require "securerandom"

RSpec.describe "Organizations", type: :request do
  let(:actor_user_id) { SecureRandom.uuid }
  let!(:organization) { Organization.create!(name: "Customer Org") }
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  before { allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client) }

  it "checks organization.read before returning an organization row" do
    expect(authorization_client).to receive(:capabilities).and_return(
      "Organization" => { organization.id.to_s => ["organization.read"] }
    )

    get "/organizations/#{organization.id}", headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => organization.id, "name" => "Customer Org")
  end

  it "allows IAM_SYSTEM to read an organization row without actor grants" do
    expect(authorization_client).not_to receive(:capabilities)

    get "/organizations/#{organization.id}", headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
  end

  it "checks batched organization capabilities once" do
    organization_ids = [organization.id, SecureRandom.uuid]
    expect(authorization_client).to receive(:capabilities).once do |targets|
      expect(targets.map(&:scope_id)).to match_array(organization_ids.map(&:to_s))
      { "Organization" => organization_ids.to_h { |id| [id.to_s, ["organization.read"]] } }
    end
    AuthorizationContext.as_requesting_user(user_id: actor_user_id) do
      Organization.authorize_records!(:read, organization_ids.map { |id| Organization.new(id: id) })
    end
  end
end
