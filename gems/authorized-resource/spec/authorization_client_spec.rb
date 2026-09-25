# frozen_string_literal: true

RSpec.describe AuthorizedModel::AuthorizationClient do
  let(:client) { described_class.new(base_url: "https://authorization.example.test/api/") }

  def response(klass, code, body = "")
    klass.new("1.1", code, nil).tap do |value|
      value.instance_variable_set(:@read, true)
      value.instance_variable_set(:@body, body)
    end
  end

  around do |example|
    original = ENV["AUTHORIZATION_CHECK_MODE"]
    original_batch_size = ENV["IAM_DEMO_BATCH_SIZE"]
    example.run
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = original
    ENV["IAM_DEMO_BATCH_SIZE"] = original_batch_size
  end

  it "batches capability requests by scope type and propagates actor context" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"
    targets = [
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-1", capability: "widget.read"),
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-2", capability: "widget.modify")
    ]
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start)
      .with("authorization.example.test", 443, use_ssl: true, open_timeout: 5, read_timeout: 30)
      .and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/api/capabilities/Account")
      expect(request["pad-user-id"]).to eq("actor-1")
      expect(JSON.parse(request.body)).to eq("scope_id" => %w[account-1 account-2])
      response(Net::HTTPOK, "200", '{"account-1":["widget.read"],"account-2":["widget.modify"]}')
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      client.capabilities(targets)
    end

    expect(result).to eq(
      "Account" => {
        "account-1" => ["widget.read"],
        "account-2" => ["widget.modify"]
      }
    )
  end

  it "asks one batched /can question per scope and capability" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    targets = [
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-1", capability: "widget.read"),
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-2", capability: "widget.read")
    ]
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/api/can/Account/widget.read")
      expect(JSON.parse(request.body)).to eq("scope_id" => %w[account-1 account-2])
      response(Net::HTTPOK, "200")
    end

    result = AuthorizationContext.as_iam { client.capabilities(targets) }

    expect(result).to eq(
      "Account" => {
        "account-1" => ["widget.read"],
        "account-2" => ["widget.read"]
      }
    )
  end

  it "maps forbidden /can responses to an empty capability result" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    target = AuthorizedModel::Target.new(
      scope_type: "Account", scope_id: "account-1", capability: "widget.read"
    )
    http = instance_double(Net::HTTP, request: response(Net::HTTPForbidden, "403"))
    allow(Net::HTTP).to receive(:start).and_yield(http)

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      client.capabilities([target])
    end

    expect(result).to eq({})
  end

  it "uses the correlated internal decision batch for composite policies in can mode" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    targets = [
      AuthorizedModel::Target.new(scope_type: "Organization", scope_id: "organization-1", capability: "organization.read.accounts"),
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-1", capability: "account.read")
    ]
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).and_yield(http)
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/api/internal/decisions")
      expect(JSON.parse(request.body).fetch("targets")).to eq([
        {"scope_type" => "Organization", "scope_id" => "organization-1", "permission" => "organization.read.accounts"},
        {"scope_type" => "Account", "scope_id" => "account-1", "permission" => "account.read"}
      ])
      response(Net::HTTPOK, "200", JSON.generate(decisions: [
        {scope_type: "Account", scope_id: "account-1", permission: "account.read", allowed: false},
        {scope_type: "Organization", scope_id: "organization-1", permission: "organization.read.accounts", allowed: true}
      ]))
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.decisions(targets) }

    expect(result).to eq(targets.first => true, targets.last => false)
  end

  it "derives correlated composite decisions from batched capability responses in capabilities mode" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"
    targets = [
      AuthorizedModel::Target.new(scope_type: "Organization", scope_id: "organization-1", capability: "organization.read.accounts"),
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: "account-1", capability: "account.read")
    ]
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).twice.and_yield(http)
    expect(http).to receive(:request).ordered.and_return(
      response(Net::HTTPOK, "200", '{"organization-1":["organization.read.accounts"]}')
    )
    expect(http).to receive(:request).ordered.and_return(
      response(Net::HTTPOK, "200", '{"account-1":[]}')
    )

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.decisions(targets) }

    expect(result).to eq(targets.first => true, targets.last => false)
  end

  it "rejects an uncorrelated internal decision" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    target = AuthorizedModel::Target.new(
      scope_type: "Account", scope_id: "account-1", capability: "account.read"
    )
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(response(Net::HTTPOK, "200", JSON.generate(decisions: [
      {scope_type: "Account", scope_id: "another-account", permission: "account.read", allowed: true}
    ])))

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.decisions([target]) }
    end.to raise_error(AuthorizedResource::AuthorizationTransportError, /uncorrelated/)
  end

  it "rejects a missing internal decision" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    target = AuthorizedModel::Target.new(
      scope_type: "Account", scope_id: "account-1", capability: "account.read"
    )
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(
      response(Net::HTTPOK, "200", JSON.generate(decisions: []))
    )

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.decisions([target]) }
    end.to raise_error(AuthorizedResource::AuthorizationTransportError, /decision count/)
  end

  it "chunks distinct /can target sets instead of issuing requests per record" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    ENV["IAM_DEMO_BATCH_SIZE"] = "2"
    targets = %w[account-1 account-1 account-2 account-3].map do |scope_id|
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: scope_id, capability: "widget.read")
    end
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).twice.and_yield(http)
    expect(http).to receive(:request).ordered do |request|
      expect(JSON.parse(request.body)).to eq("scope_id" => %w[account-1 account-2])
      response(Net::HTTPOK, "200")
    end
    expect(http).to receive(:request).ordered do |request|
      expect(JSON.parse(request.body)).to eq("scope_id" => ["account-3"])
      response(Net::HTTPOK, "200")
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      client.capabilities(targets)
    end

    expect(result.fetch("Account").keys).to eq(%w[account-1 account-2 account-3])
  end

  it "chunks distinct full-capability target sets" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"
    ENV["IAM_DEMO_BATCH_SIZE"] = "2"
    targets = %w[account-1 account-1 account-2 account-3].map do |scope_id|
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: scope_id, capability: "widget.read")
    end
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).twice.and_yield(http)
    expect(http).to receive(:request).ordered do |request|
      ids = JSON.parse(request.body).fetch("scope_id")
      expect(ids).to eq(%w[account-1 account-2])
      response(Net::HTTPOK, "200", JSON.generate(ids.to_h { |id| [id, ["widget.read"]] }))
    end
    expect(http).to receive(:request).ordered do |request|
      ids = JSON.parse(request.body).fetch("scope_id")
      expect(ids).to eq(["account-3"])
      response(Net::HTTPOK, "200", JSON.generate(ids.to_h { |id| [id, ["widget.read"]] }))
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      client.capabilities(targets)
    end

    expect(result.fetch("Account").keys).to eq(%w[account-1 account-2 account-3])
  end

  it "wraps network failures without hiding context or configuration failures" do
    target = AuthorizedModel::Target.new(
      scope_type: "Account", scope_id: "account-1", capability: "widget.read"
    )
    allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

    expect { client.capabilities([target]) }
      .to raise_error(AuthorizationContext::MissingContextError)
    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.capabilities([target]) }
    end.to raise_error(AuthorizedResource::AuthorizationTransportError, /ECONNREFUSED/)

    ENV["AUTHORIZATION_CHECK_MODE"] = "surprise"
    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") { client.capabilities([target]) }
    end.to raise_error(AuthorizedResource::AuthorizationTransportError, /unsupported/)
  end
end
