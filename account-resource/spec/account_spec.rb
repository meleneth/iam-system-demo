# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Account do
  let(:connection) { instance_double(ActiveResource::Connection) }
  let(:headers) { {"pad-user-id" => "actor"} }
  let(:response_class) { Struct.new(:body) }

  before do
    allow(described_class).to receive(:connection).and_return(connection)
    allow(described_class).to receive(:headers).and_return(headers)
  end

  it "loads a hierarchy and searches with propagated JSON requests" do
    hierarchy = instance_double(response_class, body: '[{"id":"root"},{"id":"child"}]')
    search = instance_double(response_class, body: '[{"id":"child","name":"Child"}]')
    expect(connection).to receive(:get).with("/account_with_parents/child.json", headers).and_return(hierarchy)
    expect(connection).to receive(:post).with(
      "/accounts/search", '{"id":["child"]}', headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
    ).and_return(search)

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(described_class.with_parents("child").map(&:id)).to eq(%w[root child])
      expect(described_class.search(id: ["child"]).map(&:name)).to eq(["Child"])
    end
  end

  it "chunks hierarchy batches and restores requested order" do
    original_batch_size = ENV["IAM_DEMO_BATCH_SIZE"]
    ENV["IAM_DEMO_BATCH_SIZE"] = "2"
    first = instance_double(response_class, body: '[[{"id":"a"}],[{"id":"b"}]]')
    second = instance_double(response_class, body: '[[{"id":"c"}]]')
    expect(connection).to receive(:post).ordered.and_return(first)
    expect(connection).to receive(:post).ordered.and_return(second)

    AuthorizationContext.as_requesting_user(user_id: "actor") do
      expect(described_class.with_parents_batch(%w[a b c]).map { |rows| rows.last.id }).to eq(%w[a b c])
    end

    a = described_class.new(id: "a")
    b = described_class.new(id: "b")
    expect(described_class).to receive(:with_parents_batch).with(%w[b a missing]).and_return([[b], [a]])
    expect(described_class.with_parents_batch_ordered(%w[b a missing b]).map { |rows| rows.map(&:id) })
      .to eq([%w[b], %w[a], [], %w[b]])
  ensure
    ENV["IAM_DEMO_BATCH_SIZE"] = original_batch_size
  end
end
