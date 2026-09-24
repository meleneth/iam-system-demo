# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Group do
  let(:request) { instance_double(Faraday::Request, headers: {}, body: nil) }
  let(:response_class) { Struct.new(:body) }

  before do
    allow(request).to receive(:body=)
    allow(described_class).to receive(:headers).and_return("pad-user-id" => "actor")
  end

  it "gets group counts for every requested account" do
    response = instance_double(Faraday::Response, status: 200, body: '{"account-1":3}')
    expect(Faraday).to receive(:post).with("http://group-service/accounts/groups/counts")
      .and_yield(request).and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") do
      described_class.groups_count(["account-1"])
    end
    expect(result).to eq("account-1": 3)
    expect(request).to have_received(:body=).with('{"account_id":["account-1"]}')
  end

  it "searches through the POST read endpoint" do
    connection = instance_double(ActiveResource::Connection)
    response = instance_double(response_class, body: '[{"id":"group-1"}]')
    allow(described_class).to receive(:connection).and_return(connection)
    expect(connection).to receive(:post).with(
      "/groups/search", '{"id":["group-1"]}',
      hash_including("pad-user-id" => "actor", "Content-Type" => "application/json")
    ).and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") do
      described_class.search(id: ["group-1"])
    end
    expect(result.map(&:id)).to eq(["group-1"])
  end
end
