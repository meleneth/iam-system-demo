# frozen_string_literal: true

require_relative "../rails_helper"
require "opentelemetry/sdk"

RSpec.describe AuthorizedModel::Base do
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  before do
    @previous_client = AuthorizedModel.authorization_client
    AuthorizedModel.authorization_client = authorization_client
  end

  after { AuthorizedModel.authorization_client = @previous_client }

  it "fails before SQL when context or concrete model policy is missing" do
    expect { Account.first }.to raise_error(AuthorizationContext::MissingContextError)

    stub_const("UnconfiguredAccountModel", Class.new(AuthorizedModel::Base))
    UnconfiguredAccountModel.table_name = "accounts"
    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor") { UnconfiguredAccountModel.first }
    end.to raise_error(AuthorizedResource::PolicyConfigurationError, /no explicit read/)
  end

  it "batches collection authorization against each row's actual account target" do
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    records = account_ids.map { |id| Account.new(id: id) }
    expect(authorization_client).to receive(:capabilities).once do |targets|
      expect(targets.map { |target| [target.scope_id, target.capability] }).to match_array(
        account_ids.map { |id| [id, "account.read"] }
      )
      { "Account" => account_ids.to_h { |id| [id, ["account.read"]] } }
    end

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      Account.authorize_records!(:read, records)
    end
  end

  it "authorizes create, a moving update at both parents, and destroy at the existing parent" do
    stub_const("MutableAccountModel", Class.new(AuthorizedModel::Base))
    MutableAccountModel.table_name = "accounts"
    MutableAccountModel.requires_read_capability "account.read", scope_type: "Account",
      target: :parent_account_id, iam: %w[IAM_SYSTEM]
    MutableAccountModel.requires_modify_capability "account.modify", scope_type: "Account",
      target: :parent_account_id, iam: %w[IAM_SYSTEM]

    old_parent = AuthorizationContext.as_iam { Account.create!(name: "Old parent") }
    new_parent = AuthorizationContext.as_iam { Account.create!(name: "New parent") }
    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map(&:scope_id)).to eq([old_parent.id])
      { "Account" => { old_parent.id => ["account.modify"] } }
    end
    record = AuthorizationContext.as_requesting_user(user_id: "actor") do
      MutableAccountModel.create!(name: "Child", parent_account_id: old_parent.id)
    end
    expect(authorization_client).to receive(:capabilities).ordered.and_return(
      "Account" => { old_parent.id => ["account.read"] }
    )
    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map(&:scope_id)).to match_array([old_parent.id, new_parent.id])
      { "Account" => {
        old_parent.id => ["account.modify"], new_parent.id => ["account.modify"]
      } }
    end
    AuthorizationContext.as_requesting_user(user_id: "actor") do
      record = MutableAccountModel.find(record.id)
      record.update!(parent_account_id: new_parent.id)
    end
    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map(&:scope_id)).to eq([new_parent.id])
      { "Account" => { new_parent.id => ["account.modify"] } }
    end
    AuthorizationContext.as_requesting_user(user_id: "actor") { record.destroy! }
  end

  it "isolates requesting-user context across concurrent model evaluations" do
    seen = Queue.new
    allow(authorization_client).to receive(:capabilities) do |targets|
      seen << [AuthorizationContext.current!.user_id, targets.first.scope_id]
      { "Account" => { targets.first.scope_id => ["account.read"] } }
    end
    threads = %w[user-a user-b].map do |user_id|
      account_id = SecureRandom.uuid
      Thread.new do
        AuthorizationContext.as_requesting_user(user_id: user_id) do
          Account.authorize_records!(:read, [Account.new(id: account_id)])
        end
      end
    end
    threads.each(&:join)
    expect(2.times.map { seen.pop }.map(&:first).sort).to eq(%w[user-a user-b])
  end

  it "emits one operation span with a child authorization span and no identity data" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    allow(AuthorizedResource::Instrumentation).to receive(:tracer)
      .and_return(provider.tracer("authorized-resource-test"))
    account_id = SecureRandom.uuid
    allow(authorization_client).to receive(:capabilities).and_return(
      "Account" => { account_id => ["account.read"] }
    )

    AuthorizationContext.as_requesting_user(user_id: "sensitive-user") do
      Account.authorized_read("telemetry", records: [Account.new(id: account_id)]) { :ok }
    end

    operation = exporter.finished_spans.find { |span| span.name == "authorized_resource.Account.telemetry" }
    authorization = exporter.finished_spans.find { |span| span.name == "authorized_resource.authorize" }
    expect(authorization.parent_span_id).to eq(operation.span_id)
    expect(exporter.finished_spans.count { |span| span.name == operation.name }).to eq(1)
    expect(operation.attributes.fetch("authorized_resource.outcome")).to eq("ok")
    serialized = exporter.finished_spans.flat_map { |span| span.attributes.to_a }.flatten.join(" ")
    expect(serialized).not_to include("sensitive-user", account_id, "pad-user-id")
  end
end
