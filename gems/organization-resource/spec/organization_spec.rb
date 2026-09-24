# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Organization do
  it "loads the internal random organization with request headers" do
    request = instance_double(Faraday::Request, headers: {})
    response = instance_double(Faraday::Response, status: 200, body: '{"id":"org-1"}')
    allow(described_class).to receive(:headers).and_return("pad-user-id" => "actor")
    expect(Faraday).to receive(:get).with("http://organization-service/internal/random/organization")
      .and_yield(request).and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") { described_class.random_internal }
    expect(result.id).to eq("org-1")
    expect(request.headers).to include("pad-user-id" => "actor")
  end

  it "loads organization links and their accounts" do
    account_relation = instance_double(Array, to_a: [:account])
    account_model = Class.new { def self.where(...) = nil }
    link_model = Class.new { def self.find(...) = nil }
    stub_const("Account", class_double(account_model, where: account_relation))
    stub_const("OrganizationAccount", class_double(link_model))
    link = Struct.new(:account_id).new("account-1")
    expect(OrganizationAccount).to receive(:find).with(:all, params: {organization_id: "org-1"}).twice.and_return([link])
    expect(Account).to receive(:where).with(id: ["account-1"]).and_return(account_relation)

    organization = described_class.new(id: "org-1")
    expect(organization.organization_accounts).to eq([link])
    expect(organization.accounts).to eq([:account])
  end
end
