# frozen_string_literal: true

RSpec.describe AuthorizedResource::Base do
  response_class = Struct.new(:code, :body, :headers) do
    def [](name) = headers[name]
  end

  before do
    stub_const("RemoteWidget", Class.new(described_class))
    RemoteWidget.site = "https://widgets.example.test"
    RemoteWidget.format = :json
  end

  let(:connection) { instance_double(ActiveResource::Connection) }

  before do
    allow(RemoteWidget).to receive(:connection).and_return(connection)
  end

  it "fails before transport for standard remote operations without context" do
    expect(connection).not_to receive(:get)
    expect(connection).not_to receive(:delete)

    expect { RemoteWidget.find("widget-1") }
      .to raise_error(AuthorizationContext::MissingContextError)
    expect { RemoteWidget.delete("widget-1") }
      .to raise_error(AuthorizationContext::MissingContextError)
  end

  it "preserves ActiveResource results without client-side capability evaluation" do
    authorization_client = instance_double(AuthorizedModel::AuthorizationClient)
    AuthorizedModel.authorization_client = authorization_client
    expect(authorization_client).not_to receive(:capabilities)
    response = response_class.new("200", '{"id":"widget-1","account_id":"account-1"}', {})
    expect(connection).to receive(:get)
      .with("/remote_widgets/widget-1.json", {"pad-user-id" => "actor-1"})
      .and_return(response)

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      RemoteWidget.find("widget-1")
    end

    expect(result.id).to eq("widget-1")
    expect(result.account_id).to eq("account-1")
  end

  it "builds fresh frozen headers from the active actor" do
    first = AuthorizationContext.as_requesting_user(user_id: "actor-1") { RemoteWidget.headers }
    second = AuthorizationContext.as_requesting_user(user_id: "actor-2") { RemoteWidget.headers }

    expect(first).to include("pad-user-id" => "actor-1")
    expect(second).to include("pad-user-id" => "actor-2")
    expect(first).to be_frozen
    expect(second).to be_frozen
    expect(first).not_to equal(second)
  end
end
