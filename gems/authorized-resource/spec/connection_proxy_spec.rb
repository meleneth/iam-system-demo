# frozen_string_literal: true

RSpec.describe AuthorizedResource::ConnectionProxy do
  let(:resource_class) { class_double(AuthorizedResource::Base, name: "RemoteWidget", site: nil) }
  let(:connection) { instance_double(ActiveResource::Connection) }
  let(:proxy) { described_class.new(connection, resource_class) }

  it "fails before direct connection I/O when context is missing" do
    expect(connection).not_to receive(:get)

    expect { proxy.get("/widgets", {}) }
      .to raise_error(AuthorizationContext::MissingContextError)
  end

  it "adds requesting-user context without mutating supplied headers" do
    supplied = {"Accept" => "application/json"}.freeze
    expect(connection).to receive(:get).with(
      "/widgets",
      {"Accept" => "application/json", "pad-user-id" => "actor-1"}
    ).and_return(:response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      proxy.get("/widgets", supplied)
    end

    expect(result).to eq(:response)
    expect(supplied).to eq("Accept" => "application/json")
  end

  it "puts context in the third argument for body-carrying methods" do
    expect(connection).to receive(:post)
      .with("/widgets/search", "{}", {"pad-user-id" => "IAM_SYSTEM"})
      .and_return(:response)

    result = AuthorizationContext.as_iam do
      proxy.post("/widgets/search", "{}", {})
    end

    expect(result).to eq(:response)
  end

  it "delegates non-HTTP connection methods" do
    expect(connection).to receive(:site).and_return(URI("https://widgets.example.test"))

    expect(proxy.site.host).to eq("widgets.example.test")
    expect(proxy).to respond_to(:site)
  end
end
