require "rails_helper"

RSpec.describe "Organization authorization boundaries", type: :request do
  def grant_group_id(actor)
    @grant_group_ids ||= {}
    @grant_group_ids[actor] ||= SecureRandom.uuid
  end

  before do
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).and_return({"accounts" => []})
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for) do |_client, actor|
      [grant_group_id(actor)]
    end
  end

  let(:actor) { SecureRandom.uuid }
  let(:other_actor) { SecureRandom.uuid }
  let(:msp_a) { SecureRandom.uuid }
  let(:msp_b) { SecureRandom.uuid }

  before do
    stub_const("AUTHORIZATION_CACHE", IamDemo::NullRedisCache.new)
    CapabilityGrant.create!(group_id: grant_group_id(actor), permission: "organization.users.manage", scope_type: "Organization", scope_id: msp_a)
    CapabilityGrant.create!(group_id: grant_group_id(actor), permission: "organization.read.accounts", scope_type: "Organization", scope_id: msp_a)
    CapabilityGrant.create!(group_id: grant_group_id(other_actor), permission: "organization.read.accounts", scope_type: "Organization", scope_id: msp_b)
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
    CapabilityGrant.create!(group_id: grant_group_id(actor), permission: "organization.read.accounts", scope_type: "Account", scope_id: msp_b)
    expect(decision([msp_b], as: other_actor)).to eq(200)
    expect(decision([msp_b])).to eq(403)
    expect(decision([msp_a], permission: "organization.accounts.create")).to eq(403)
    expect(decision([msp_b], permission: "organization.users.manage")).to eq(403)
  end

  it "keeps capability batch decisions distinct" do
    post "/capabilities/Organization", params: { scope_id: [msp_a, msp_b] }, headers: { "pad-user-id" => actor }, as: :json
    expect(response.parsed_body).to eq(msp_a => ["organization.read.accounts", "organization.users.manage"], msp_b => [])
  end
end
