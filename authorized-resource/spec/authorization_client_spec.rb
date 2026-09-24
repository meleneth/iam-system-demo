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
    example.run
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = original
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

  it "narrows a forbidden /can batch to the authorized IDs" do
    ENV["AUTHORIZATION_CHECK_MODE"] = "can"
    targets = %w[account-1 account-2].map do |scope_id|
      AuthorizedModel::Target.new(scope_type: "Account", scope_id: scope_id, capability: "widget.read")
    end
    http = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).exactly(3).times.and_yield(http)
    expect(http).to receive(:request).ordered do |request|
      expect(JSON.parse(request.body)).to eq("scope_id" => %w[account-1 account-2])
      response(Net::HTTPForbidden, "403")
    end
    expect(http).to receive(:request).ordered do |request|
      expect(JSON.parse(request.body)).to eq("scope_id" => ["account-1"])
      response(Net::HTTPOK, "200")
    end
    expect(http).to receive(:request).ordered do |request|
      expect(JSON.parse(request.body)).to eq("scope_id" => ["account-2"])
      response(Net::HTTPForbidden, "403")
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      client.capabilities(targets)
    end

    expect(result).to eq("Account" => {"account-1" => ["widget.read"]})
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
