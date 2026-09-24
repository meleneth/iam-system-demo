# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CapabilityGrant do
  let(:request) { instance_double(Faraday::Request, headers: {}) }

  before do
    allow(described_class).to receive(:headers).and_return("pad-user-id" => "actor")
  end

  it "returns the organization admin and handles a missing admin" do
    found = instance_double(Faraday::Response, status: 200, body: '{"id":"user-1"}')
    missing = instance_double(Faraday::Response, status: 404, body: "")
    expect(Faraday).to receive(:get).twice.and_yield(request).and_return(found, missing)

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(described_class.admin_user_for_organization("org-1")).to eq(id: "user-1")
      expect(described_class.admin_user_for_organization("org-2")).to be_nil
    end
  end

  it "retrieves capabilities only for the current actor" do
    response = instance_double(Faraday::Response, status: 200, body: '["account.read"]')
    expect(Faraday).to receive(:get).with("http://authorization-service/capabilities/Account/account-1")
      .and_yield(request).and_return(response)

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(described_class.capabilities("Account", "account-1", user_id: "actor")).to eq(["account.read"])
      expect { described_class.capabilities("Account", "account-1", user_id: "someone-else") }
        .to raise_error(AuthorizationContext::InvalidContextError)
    end
  end
end
