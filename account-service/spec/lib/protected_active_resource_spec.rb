# frozen_string_literal: true

require_relative "../rails_helper"

RSpec.describe AuthorizedResource::AuthorizationClient do
  subject(:client) { described_class.new(base_url: "http://authorization.test") }

  let(:target) do
    AuthorizedResource::Target.new(
      scope_type: "Account", scope_id: "account-1", capability: "account.users.read"
    )
  end
  let(:http) { instance_double(Net::HTTP) }

  around do |example|
    previous = ENV["AUTHORIZATION_CHECK_MODE"]
    AuthorizationContext.as_requesting_user(user_id: "actor") { example.run }
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = previous
  end

  it "uses one precise batched /can request in can mode" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    response = Net::HTTPOK.new("1.1", "200", "OK")
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/can/Account/account.users.read")
      expect(JSON.parse(request.body)).to eq("scope_id" => ["account-1"])
      response
    end

    expect(client.capabilities([target])).to eq(
      "Account" => { "account-1" => ["account.users.read"] }
    )
  end

  it "keeps a /can denial distinct from transport failure" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    response = Net::HTTPForbidden.new("1.1", "403", "Forbidden")
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(response)

    expect(client.capabilities([target])).to eq({})
  end

  it "uses the batched capabilities endpoint only in capabilities mode" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.body = JSON.generate("account-1" => ["account.users.read"])
    response.instance_variable_set(:@read, true)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/capabilities/Account")
      response
    end

    expect(client.capabilities([target])).to eq(
      "Account" => { "account-1" => ["account.users.read"] }
    )
  end
end

RSpec.describe AuthorizedResource::ConnectionProxy do
  let(:connection) { instance_double(ActiveResource::Connection) }
  let(:proxy) { described_class.new(connection) }

  it "rejects unclassified direct connection calls" do
    expect(connection).not_to receive(:get)
    expect { proxy.get("/users", {}) }
      .to raise_error(AuthorizedResource::UnsupportedOperationError, /authorized_read/)
  end

  it "derives request metadata at execution time and isolates concurrent callers" do
    seen = Queue.new
    allow(connection).to receive(:get) { |_path, headers| seen << headers.fetch("pad-user-id") }

    threads = %w[user-a user-b].map do |user_id|
      Thread.new do
        AuthorizationContext.as_requesting_user(user_id: user_id) do
          AuthorizedResource::Operation.within(User, :find, :read) { proxy.get("/users", {}) }
        end
      end
    end
    threads.each(&:join)

    expect(2.times.map { seen.pop }.sort).to eq(%w[user-a user-b])
  end
end

RSpec.describe AuthorizedResource::Base do
  let(:authorization_client) { instance_double(AuthorizedResource::AuthorizationClient) }

  before do
    @previous_client = AuthorizedResource.authorization_client
    AuthorizedResource.authorization_client = authorization_client
  end

  after { AuthorizedResource.authorization_client = @previous_client }

  it "fails closed for missing context before transport and missing model policy" do
    expect { User.find("user-1") }.to raise_error(AuthorizationContext::MissingContextError)

    unconfigured = Class.new(AuthorizedResource::Base)
    allow(unconfigured).to receive(:name).and_return("UnconfiguredResource")
    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor") { unconfigured.find("one") }
    end.to raise_error(AuthorizedResource::PolicyConfigurationError, /no explicit read/)
  end

  it "uses the owning account target and configured read capability" do
    expect(authorization_client).to receive(:capabilities) do |targets|
      expect(targets.map { |target| [target.scope_type, target.scope_id, target.capability] })
        .to eq([["Account", "account-1", "account.users.read"]])
      { "Account" => { "account-1" => ["account.users.read"] } }
    end

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(User.authorize_records!(:read, [User.new(id: "user-1", account_id: "account-1")])).to be_present
    end
  end

  it "denies mixed-account collections and batches evaluation into one client call" do
    expect(authorization_client).to receive(:capabilities).once.and_return(
      "Account" => {
        "account-a" => ["account.users.read"],
        "account-b" => []
      }
    )
    records = [
      User.new(id: "user-a", account_id: "account-a"),
      User.new(id: "user-b", account_id: "account-b")
    ]

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor") do
        User.authorize_records!(:read, records, operation: :find)
      end
    end.to raise_error(AuthorizedResource::AuthorizationDenied)
  end

  it "keeps denied decisions distinct from authorization transport failures" do
    allow(authorization_client).to receive(:capabilities).and_raise(
      AuthorizedResource::AuthorizationTransportError, "unavailable"
    )
    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor") do
        User.authorize_records!(:read, [User.new(account_id: "account-1")])
      end
    end.to raise_error(AuthorizedResource::AuthorizationTransportError, "unavailable")
  end

  it "allows only explicitly configured IAM readers and preserves nested contexts" do
    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect do
        AuthorizationContext.as_iam(originating_user_id: "actor") do
          User.authorize_records!(:read, [User.new(account_id: "account-1")])
        end
      end.not_to raise_error
      expect(AuthorizationContext.current!.user_id).to eq("actor")
    end

    expect do
      AuthorizationContext.as_iam(identity: "IAM_SYSTEM_AUTH") do
        User.authorize_records!(:read, [User.new(account_id: "account-1")])
      end
    end.to raise_error(AuthorizedResource::AuthorizationDenied, /IAM_SYSTEM_AUTH/)
  end

  it "makes intentional read-only policy explicit for every mutation path" do
    resource = User.new(id: "user-1", account_id: "account-1")
    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect { resource.save }.to raise_error(AuthorizedResource::ReadOnlyError)
      expect { resource.destroy }.to raise_error(AuthorizedResource::ReadOnlyError)
      expect { resource.put(:promote) }.to raise_error(AuthorizedResource::ReadOnlyError)
    end
  end

  it "authorizes create against its container and update against both old and new scopes" do
    stub_const("MutableWidgetResource", Class.new(AuthorizedResource::Base))
    MutableWidgetResource.site = "http://resource-service.test"
    MutableWidgetResource.format = :json
    MutableWidgetResource.requires_read_capability "widget.read", scope_type: "Account", target: :account_id
    MutableWidgetResource.requires_modify_capability "widget.modify", scope_type: "Account", target: :account_id

    response_class = Struct.new(:code, :body, :headers) do
      def [](name) = headers[name]
    end
    connection = instance_double(ActiveResource::Connection)
    allow(MutableWidgetResource).to receive(:connection).and_return(connection)
    allow(connection).to receive(:post).and_return(response_class.new("201", "", {}))
    allow(connection).to receive(:put).and_return(response_class.new("204", "", {}))

    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map { |target| [target.scope_id, target.capability] }).to eq([["container-a", "widget.modify"]])
      { "Account" => { "container-a" => ["widget.modify"] } }
    end
    expect(authorization_client).to receive(:capabilities).ordered.and_return(
      "Account" => { "container-a" => ["widget.read"] }
    )
    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map { |target| [target.scope_id, target.capability] }.sort).to eq(
        [["container-a", "widget.modify"], ["container-b", "widget.modify"]]
      )
      { "Account" => { "container-a" => ["widget.modify"], "container-b" => ["widget.modify"] } }
    end

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      MutableWidgetResource.new(account_id: "container-a").save
      existing = MutableWidgetResource.new({ id: "widget-1", account_id: "container-a" }, true)
      MutableWidgetResource.authorize_records!(:read, [existing])
      existing.account_id = "container-b"
      existing.save
    end

    expect(connection).to have_received(:post).once
    expect(connection).to have_received(:put).once
  end

  it "authorizes delete against the existing target before transport" do
    stub_const("DestroyableWidgetResource", Class.new(AuthorizedResource::Base))
    DestroyableWidgetResource.site = "http://resource-service.test"
    DestroyableWidgetResource.requires_read_capability "widget.read", scope_type: "Account", target: :account_id
    DestroyableWidgetResource.requires_modify_capability "widget.modify", scope_type: "Account", target: :account_id
    connection = instance_double(ActiveResource::Connection)
    allow(DestroyableWidgetResource).to receive(:connection).and_return(connection)
    expect(connection).to receive(:delete)
    expect(authorization_client).to receive(:capabilities) do |targets|
      expect(targets.map(&:scope_id)).to eq(["container-a"])
      { "Account" => { "container-a" => ["widget.modify"] } }
    end

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      DestroyableWidgetResource.new({ id: "widget-1", account_id: "container-a" }, true).destroy
    end
  end

  it "guards associations, reloads, existence checks and custom/batch endpoints" do
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
