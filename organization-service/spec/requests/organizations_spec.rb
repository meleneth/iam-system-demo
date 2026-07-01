require "rails_helper"
require "securerandom"

RSpec.describe "Organizations", type: :request do
  FakeFaradayResponse = Struct.new(:status, :body)
  FakeFaradayRequest = Struct.new(:headers, :body, keyword_init: true)

  let(:actor_user_id) { SecureRandom.uuid }
  let!(:organization) { Organization.create!(name: "Customer Org") }

  it "checks organization.read before returning an organization row" do
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.read", organization.id)
      .and_return(true)

    get "/organizations/#{organization.id}", headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => organization.id, "name" => "Customer Org")
  end

  it "allows IAM_SYSTEM to read an organization row without actor grants" do
    expect(User).not_to receive(:user_can)

    get "/organizations/#{organization.id}", headers: { "pad-user-id" => "IAM_SYSTEM" }

    expect(response).to have_http_status(:ok)
  end

  it "checks batched organization capabilities instead of calling /can in capabilities-only mode" do
    organization_ids = [organization.id, SecureRandom.uuid]
    request = nil
    old_mode = ENV["AUTHORIZATION_CHECK_MODE"]
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"

    expect(Faraday).to receive(:post).with("#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/Organization") do |&block|
      request = FakeFaradayRequest.new(headers: {})
      block.call(request)
      FakeFaradayResponse.new(
        200,
        organization_ids.to_h { |organization_id| [organization_id, ["organization.read"]] }.to_json
      )
    end

    expect(User.user_can(actor_user_id, "Organization", "organization.read", organization_ids)).to eq(true)
    expect(JSON.parse(request.body)).to eq("scope_id" => organization_ids)
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = old_mode
  end
end
