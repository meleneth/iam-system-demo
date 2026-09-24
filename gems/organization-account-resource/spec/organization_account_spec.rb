# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe OrganizationAccount do
  let(:request) { instance_double(Faraday::Request, headers: {}, body: nil) }

  before do
    allow(request).to receive(:body=)
    allow(described_class).to receive(:headers).and_return("pad-user-id" => "actor")
  end

  it "maps account IDs to organizations in one authorized lookup" do
    body = '{"organizations":{"org-1":["account-1"]},"account_to_organization":{"account-1":"org-1"}}'
    response = instance_double(Faraday::Response, status: 200, body: body)
    expect(Faraday).to receive(:post)
      .with("http://organization-service/organization_account_ids/for_account_ids")
      .and_yield(request).and_return(response)
    organization_model = Class.new do
      def initialize(**) = nil
      def self.find(...) = nil
    end
    stub_const("Organization", class_double(organization_model))
    remote_organization = Struct.new(:id).new("org-1")
    allow(Organization).to receive(:new).with(id: "org-1").and_return(remote_organization)
    expect(Organization).to receive(:find).with("org-1").and_return(remote_organization)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") do
      described_class.account_ids_for_organization_by_account_id("account-1")
    end
    expect(result[:organization].id).to eq("org-1")
    expect(result[:account_ids]).to eq(["account-1"])
  end

  it "loads account counts and a random account" do
    count_response = instance_double(Faraday::Response, status: 200, body: '{"accounts_count":2}')
    random_response = instance_double(Faraday::Response, status: 200, body: '{"id":"account-1"}')
    expect(Faraday).to receive(:get).ordered
      .with("http://organization-service/organizations/accounts/counts/org-1")
      .and_yield(request).and_return(count_response)
    expect(Faraday).to receive(:get).ordered
      .with("http://organization-service/internal/random/organizations/org-1/account")
      .and_yield(request).and_return(random_response)

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(described_class.accounts_counts("org-1")).to eq(accounts_count: 2)
      expect(described_class.random_account_for_organization("org-1")).to eq(id: "account-1")
    end
  end

  it "loads its organization through the shared model" do
    model = Class.new { def self.find(...) = nil }
    stub_const("Organization", class_double(model))
    expect(Organization).to receive(:find).with("org-1").and_return(:organization)
    expect(described_class.new(organization_id: "org-1").organization).to eq(:organization)
  end
end
