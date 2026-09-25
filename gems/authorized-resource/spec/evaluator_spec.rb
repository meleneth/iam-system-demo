# frozen_string_literal: true

RSpec.describe AuthorizedModel::Base do
  before do
    stub_const("ProtectedWidget", Class.new(AuthorizedModel::Base))
    ProtectedWidget.requires_read_capability "widget.read", scope_type: "Account", target: :account_id,
      iam: %w[IAM_SYSTEM]
    ProtectedWidget.requires_modify_capability "widget.modify", scope_type: "Account", target: :account_id,
      iam: %w[IAM_SYSTEM]
  end

  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }
  let(:record_class) { Struct.new(:account_id) }

  before do
    AuthorizedModel.authorization_client = authorization_client
  end

  it "batches capability evaluation across the records' actual targets" do
    records = [record_class.new("account-1"), record_class.new("account-2")]
    expect(authorization_client).to receive(:capabilities).once do |targets|
      expect(targets.map { |target| [target.scope_type, target.scope_id, target.capability] })
        .to contain_exactly(
          ["Account", "account-1", "widget.read"],
          ["Account", "account-2", "widget.read"]
        )
      {
        "Account" => {
          "account-1" => ["widget.read"],
          "account-2" => ["widget.read"]
        }
      }
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      ProtectedWidget.authorize_records!(:read, records)
    end

    expect(result).to eq(records)
  end

  it "denies the whole batch when any record has no permitted target" do
    records = [record_class.new("account-1"), record_class.new("account-2")]
    expect(authorization_client).to receive(:capabilities).and_return(
      "Account" => {"account-1" => ["widget.read"]}
    )

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") do
        ProtectedWidget.authorize_records!(:read, records)
      end
    end.to raise_error(AuthorizedResource::AuthorizationDenied, /authorization denied/)
  end

  it "allows each record through either branch of one composite read policy" do
    stub_const("RelationshipWidget", Class.new(AuthorizedModel::Base))
    RelationshipWidget.requires_read_any_capability(
      { capability: "organization.read.widgets", scope_type: "Organization", target: :organization_id },
      { capability: "widget.read", scope_type: "Account", target: :account_id }
    )
    relationship_class = Struct.new(:organization_id, :account_id)
    records = [
      relationship_class.new("organization-1", "account-1"),
      relationship_class.new("organization-2", "account-2")
    ]
    expect(authorization_client).to receive(:decisions).once do |targets|
      expect(targets.map { |target| [target.scope_type, target.scope_id, target.capability] })
        .to contain_exactly(
          ["Organization", "organization-1", "organization.read.widgets"],
          ["Account", "account-1", "widget.read"],
          ["Organization", "organization-2", "organization.read.widgets"],
          ["Account", "account-2", "widget.read"]
        )
      targets.to_h do |target|
        allowed = target.scope_id == "organization-1" || target.scope_id == "account-2"
        [target, allowed]
      end
    end

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      RelationshipWidget.authorize_records!(:read, records)
    end

    expect(result).to eq(records)
  end

  it "denies a composite collection when one row satisfies neither branch" do
    stub_const("RelationshipWidget", Class.new(AuthorizedModel::Base))
    RelationshipWidget.requires_read_any_capability(
      { capability: "organization.read.widgets", scope_type: "Organization", target: :organization_id },
      { capability: "widget.read", scope_type: "Account", target: :account_id }
    )
    relationship_class = Struct.new(:organization_id, :account_id)
    records = [
      relationship_class.new("organization-1", "account-1"),
      relationship_class.new("organization-2", "account-2"),
      relationship_class.new("organization-3", "account-3")
    ]
    allow(authorization_client).to receive(:decisions) do |targets|
      targets.to_h do |target|
        allowed = target.scope_id == "organization-1" || target.scope_id == "account-2"
        [target, allowed]
      end
    end

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") do
        RelationshipWidget.authorize_records!(:read, records)
      end
    end.to raise_error(AuthorizedResource::AuthorizationDenied, /authorization denied/)
  end

  it "rejects unresolved authorization targets without consulting the service" do
    expect(authorization_client).not_to receive(:capabilities)

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") do
        ProtectedWidget.authorize_records!(:read, [record_class.new(nil)])
      end
    end.to raise_error(AuthorizedResource::PolicyConfigurationError, /could not resolve/)
  end

  it "allows only explicitly configured IAM identities without a capability lookup" do
    expect(authorization_client).not_to receive(:capabilities)

    result = AuthorizationContext.as_iam do
      ProtectedWidget.authorize_records!(:modify, [record_class.new("account-1")])
    end
    expect(result.size).to eq(1)

    expect do
      AuthorizationContext.as_iam(identity: "IAM_SYSTEM_AUTH") do
        ProtectedWidget.authorize_records!(:modify, [record_class.new("account-1")])
      end
    end.to raise_error(AuthorizedResource::AuthorizationDenied, /IAM_SYSTEM_AUTH/)
  end

  it "fails closed for missing policies and read-only modifications" do
    stub_const("UnconfiguredWidget", Class.new(AuthorizedModel::Base))
    stub_const("ReadOnlyWidget", Class.new(AuthorizedModel::Base))
    ReadOnlyWidget.read_only!(iam: %w[IAM_SYSTEM])

    expect do
      AuthorizationContext.as_requesting_user(user_id: "actor-1") do
        UnconfiguredWidget.authorize_records!(:read, [record_class.new("account-1")])
      end
    end.to raise_error(AuthorizedResource::PolicyConfigurationError, /no explicit read/)

    expect do
      AuthorizationContext.as_iam do
        ReadOnlyWidget.authorize_records!(:modify, [record_class.new("account-1")])
      end
    end.to raise_error(AuthorizedResource::ReadOnlyError, /explicitly read-only/)
  end

  it "keeps sibling model declarations independent" do
    stub_const("SiblingWidget", Class.new(AuthorizedModel::Base))

    expect(SiblingWidget.read_requirement).to be_nil
    expect(SiblingWidget.iam_readers).to be_empty
    expect(ProtectedWidget.read_requirement.capability).to eq("widget.read")
    expect(ProtectedWidget.iam_readers).to eq(["IAM_SYSTEM"])
  end

  it "rejects a second read-policy declaration" do
    expect do
      ProtectedWidget.requires_read_capability "widget.audit", scope_type: "Account", target: :account_id
    end.to raise_error(AuthorizedResource::PolicyConfigurationError, /already has an explicit read/)

    expect(ProtectedWidget.read_requirement.capability).to eq("widget.read")
    expect(ProtectedWidget.iam_readers).to eq(["IAM_SYSTEM"])
  end
end
