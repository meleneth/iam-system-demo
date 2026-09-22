# frozen_string_literal: true

require_relative "../rails_helper"
require "opentelemetry/sdk"

RSpec.describe AuthorizedResource::ConnectionProxy do
  let(:connection) { instance_double(ActiveResource::Connection) }
  let(:proxy) { described_class.new(connection, User) }

  it "requires context before direct connection I/O" do
    expect(connection).not_to receive(:get)
    expect { proxy.get("/users", {}) }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "propagates requesting-user context without mutating supplied headers" do
    supplied = { "Accept" => "application/json" }.freeze
    expect(connection).to receive(:get) do |_path, headers|
      expect(headers).to include(
        "Accept" => "application/json",
        "pad-user-id" => "actor",
        "X-IAM-Authorization-Scope" => "requesting-user",
        "X-IAM-Originating-User-ID" => "actor"
      )
      :response
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor") do
      proxy.get("/users", supplied)
    end

    expect(result).to eq(:response)
    expect(supplied).to eq("Accept" => "application/json")
  end

  it "propagates authenticated IAM authority and originating-user attribution" do
    previous_token = ENV["IAM_INTERNAL_TOKEN"]
    ENV["IAM_INTERNAL_TOKEN"] = "internal-secret"
    expect(connection).to receive(:post) do |_path, _body, headers|
      expect(headers).to include(
        "pad-user-id" => "IAM_SYSTEM",
        "X-IAM-Authorization-Scope" => "iam",
        "X-IAM-Originating-User-ID" => "originator",
        "X-IAM-Internal-Token" => "internal-secret"
      )
      :response
    end

    result = AuthorizationContext.as_requesting_user(user_id: "originator") do
      AuthorizationContext.as_iam { proxy.post("/users/search", "{}", {}) }
    end

    expect(result).to eq(:response)
    expect(AuthorizationContext.current).to be_nil
  ensure
    ENV["IAM_INTERNAL_TOKEN"] = previous_token
  end

  it "isolates concurrent request metadata" do
    seen = Queue.new
    allow(connection).to receive(:get) { |_path, headers| seen << headers.fetch("pad-user-id") }

    threads = %w[user-a user-b].map do |user_id|
      Thread.new do
        AuthorizationContext.as_requesting_user(user_id: user_id) { proxy.get("/users", {}) }
      end
    end
    threads.each(&:join)

    expect(2.times.map { seen.pop }.sort).to eq(%w[user-a user-b])
  end
end

RSpec.describe AuthorizedResource::Base do
  response_class = Struct.new(:code, :body, :headers) do
    def [](name) = headers[name]
  end

  it "raises before transport for every supported retrieval and mutation path" do
    connection = instance_double(ActiveResource::Connection)
    allow(User).to receive(:connection).and_return(connection)
    resource = User.new({ "id" => "user-1" }, true)
    retrievals = [
      -> { User.find("user-1") },
      -> { User.find(:all, params: { account_id: "account-1" }) },
      -> { User.build },
      -> { User.exists?("user-1") },
      -> { resource.reload },
      -> { User.get(:recent) },
      -> { User.authorized_read("batch") { User.connection.get("/users/search", {}) } }
    ]
    mutations = [
      -> { User.new.save },
      -> { resource.save },
      -> { resource.destroy },
      -> { User.delete("user-1") },
      -> { User.post(:refresh) },
      -> { resource.patch(:refresh) }
    ]

    (retrievals + mutations).each do |operation|
      expect(&operation).to raise_error(AuthorizationContext::MissingContextError)
    end
  end

  it "does not evaluate capabilities before or after retrieval" do
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    previous_client = AuthorizedModel.authorization_client
    AuthorizedModel.authorization_client = authorization_client
    expect(authorization_client).not_to receive(:capabilities)
    connection = instance_double(ActiveResource::Connection)
    response = response_class.new("200", '{"id":"user-1","account_id":"account-1"}', {})
    allow(User).to receive(:connection).and_return(connection)
    expect(connection).to receive(:get).once.and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") { User.find("user-1") }

    expect(result.id).to eq("user-1")
  ensure
    AuthorizedModel.authorization_client = previous_client
  end

  it "preserves ActiveResource mutation results and transport errors" do
    connection = instance_double(ActiveResource::Connection)
    allow(User).to receive(:connection).and_return(connection)
    created = response_class.new(
      "201", '{"id":"user-1"}',
      { "Location" => "/users/user-1", "Content-Length" => "15" }
    )
    allow(connection).to receive(:post).and_return(created)
    allow(connection).to receive(:put).and_raise(ActiveResource::ServerError.new(created))

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      resource = User.new
      expect(resource.save).to be_truthy
      resource.id = "user-1"
      expect { resource.save }.to raise_error(ActiveResource::ServerError)
    end
  end

  it "emits one resource span without a client-side authorization span or identity data" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    allow(AuthorizedResource::Instrumentation).to receive(:tracer)
      .and_return(provider.tracer("authorized-resource-test"))
    connection = instance_double(ActiveResource::Connection)
    response = response_class.new("200", '{"id":"user-1"}', {})
    allow(User).to receive(:connection).and_return(connection)
    allow(connection).to receive(:get).and_return(response)

    AuthorizationContext.as_requesting_user(user_id: "sensitive-user") { User.find("user-1") }

    spans = exporter.finished_spans
    expect(spans.count { |span| span.name == "authorized_resource.User.find" }).to eq(1)
    expect(spans.none? { |span| span.name == "authorized_resource.authorize" }).to be(true)
    expect(spans.first.attributes.fetch("authorized_resource.outcome")).to eq("ok")
    expect(spans.flat_map { |span| span.attributes.to_a }.flatten.join(" "))
      .not_to include("sensitive-user", "pad-user-id")
  end

  it "restores nested context after transport exceptions" do
    connection = instance_double(ActiveResource::Connection)
    allow(User).to receive(:connection).and_return(connection)
    allow(connection).to receive(:get).and_raise(ActiveResource::TimeoutError, "timeout")

    AuthorizationContext.as_requesting_user(user_id: "outer") do
      expect do
        AuthorizationContext.as_requesting_user(user_id: "inner") { User.find("user-1") }
      end.to raise_error(ActiveResource::TimeoutError)
      expect(AuthorizationContext.current!.user_id).to eq("outer")
    end
  end
end
