require "rails_helper"

RSpec.describe "Organization authorization boundaries", type: :request do
  let(:actor) { SecureRandom.uuid }
  let(:other_actor) { SecureRandom.uuid }
  let(:msp_a) { SecureRandom.uuid }
  let(:msp_b) { SecureRandom.uuid }

  before do
    stub_const("AUTHORIZATION_CACHE", IamDemo::NullRedisCache.new)
    CapabilityGrant.create!(user_id: actor, permission: "msp.admin.users", scope_type: "Organization", scope_id: msp_a)
    CapabilityGrant.create!(user_id: actor, permission: "organization.read.accounts", scope_type: "Organization", scope_id: msp_a)
    CapabilityGrant.create!(user_id: other_actor, permission: "organization.read.accounts", scope_type: "Organization", scope_id: msp_b)
  end

  def decision(ids, permission: "organization.read.accounts", as: actor)
    post "/can/Organization/#{permission}", params: { scope_id: ids }, headers: { "pad-user-id" => as }, as: :json
    response.status
  end

  it "requires an independently justified grant on every organization in a mixed batch" do
    expect(decision([msp_a])).to eq(200)
    expect(decision([msp_b])).to eq(403)
    expect(decision([msp_a, msp_b])).to eq(403)
  end

  it "does not merge principals, permissions or scope types" do
    CapabilityGrant.create!(user_id: actor, permission: "organization.read.accounts", scope_type: "Account", scope_id: msp_b)
    expect(decision([msp_b], as: other_actor)).to eq(200)
    expect(decision([msp_b])).to eq(403)
    expect(decision([msp_a], permission: "organization.accounts.create")).to eq(403)
    expect(decision([msp_b], permission: "msp.admin.users")).to eq(403)
  end

  it "keeps capability batch decisions distinct" do
    post "/capabilities/Organization", params: { scope_id: [msp_a, msp_b] }, headers: { "pad-user-id" => actor }, as: :json
    expect(response.parsed_body).to eq(msp_a => ["msp.admin.users", "organization.read.accounts"], msp_b => [])
  end
end
