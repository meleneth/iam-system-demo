# frozen_string_literal: true

require_relative "../rails_helper"

RSpec.describe AuthorizationContext::ActiveResourceProtection::ConnectionProxy do
  let(:connection) { instance_double(ActiveResource::Connection) }
  let(:proxy) { described_class.new(connection, -> { AuthorizationContext.transport_headers }) }

  it "raises before collection or single-record HTTP is performed without context" do
    expect(connection).not_to receive(:get)
    expect { proxy.get("/users", {}) }.to raise_error(AuthorizationContext::MissingContextError)
    expect { proxy.get("/users/1", {}) }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "adds per-request user metadata without retaining it" do
    expect(connection).to receive(:get).with("/users/1", hash_including("pad-user-id" => "user-1"))
    AuthorizationContext.as_requesting_user(user_id: "user-1") { proxy.get("/users/1", {}) }
    expect { proxy.get("/users/2", {}) }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "guards deferred invocations and isolates concurrent metadata" do
    captured = AuthorizationContext.as_requesting_user(user_id: "user-1") { proxy }
    expect { captured.get("/users", {}) }.to raise_error(AuthorizationContext::MissingContextError)

    seen = Queue.new
    allow(connection).to receive(:get) { |_path, headers| seen << headers.fetch("pad-user-id") }
    threads = %w[user-a user-b].map do |user_id|
      Thread.new { AuthorizationContext.as_requesting_user(user_id: user_id) { proxy.get("/users", {}) } }
    end
    threads.each(&:join)
    expect(2.times.map { seen.pop }.sort).to eq(%w[user-a user-b])
  end
end

RSpec.describe "protected ActiveResource retrieval paths" do
  it "guards single, collection, existence, reload, custom and association reads" do
    retrievals = [
      -> { User.find("user-1") },
      -> { User.find(:all, params: { account_id: "account-1" }) },
      -> { User.exists?("user-1") },
      -> { User.new(id: "user-1").reload },
      -> { OrganizationAccount.account_ids_for_organizations_by_account_ids(["account-1"]) },
      -> { OrganizationAccount.new(organization_id: "org-1").organization }
    ]
    retrievals.each { |retrieval| expect(&retrieval).to raise_error(AuthorizationContext::MissingContextError) }
  end
end
