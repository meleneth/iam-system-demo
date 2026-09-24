# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GroupUser do
  let(:response_class) { Struct.new(:body) }

  it "searches memberships through the POST read endpoint" do
    connection = instance_double(ActiveResource::Connection)
    response = instance_double(response_class, body: '[{"id":"membership-1","group_id":"group-1"}]')
    allow(described_class).to receive(:connection).and_return(connection)
    allow(described_class).to receive(:headers).and_return("pad-user-id" => "actor")
    expect(connection).to receive(:post).with(
      "/group_users/search", '{"user_id":["user-1"]}',
      hash_including("pad-user-id" => "actor", "Content-Type" => "application/json")
    ).and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor") do
      described_class.search(user_id: ["user-1"])
    end
    expect(result.map(&:group_id)).to eq(["group-1"])
  end
end
