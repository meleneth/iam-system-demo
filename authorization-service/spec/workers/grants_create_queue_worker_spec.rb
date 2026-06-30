require "rails_helper"
require Rails.root.join("app/workers/grants_create_queue_worker")
require "json"
require "securerandom"

RSpec.describe GrantsCreateQueueWorker do
  FakeMessage = Struct.new(:body, :receipt_handle)

  let(:worker) { described_class.new(queue_url: "http://example.test/grants_create") }
  let(:user_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:organization_id) { SecureRandom.uuid }
  let(:users_group_id) { SecureRandom.uuid }
  let(:admins_group_id) { SecureRandom.uuid }

  before do
    allow(worker).to receive(:delete)
  end

  it "is idempotent when the same user-create event is delivered more than once" do
    msg = message(
      user: { id: user_id, email: "admin@example.com", account_id: account_id, is_admin: true },
      account: { id: account_id, parent_account_id: nil },
      organization: { id: organization_id },
      groups: [
        { id: users_group_id, name: "Users" },
        { id: admins_group_id, name: "Admins" }
      ]
    )

    expect { worker.process(msg) }.to change(CapabilityGrant, :count).by(11)
    expect { worker.process(msg) }.not_to change(CapabilityGrant, :count)
    expect(worker).to have_received(:delete).twice
  end

  it "deduplicates repeated groups inside one event before inserting grants" do
    msg = message(
      user: { id: user_id, email: "user@example.com", account_id: account_id, is_admin: false },
      account: { id: account_id, parent_account_id: nil },
      organization: { id: organization_id },
      groups: [
        { id: users_group_id, name: "Users" },
        { id: users_group_id, name: "Users" }
      ]
    )

    expect { worker.process(msg) }.to change(CapabilityGrant, :count).by(5)
    expect(CapabilityGrant.where(user_id: user_id, permission: "group.read", scope_id: users_group_id).count).to eq(1)
  end

  it "projects MSP admin grants only from explicit MSP admin seed events" do
    msg = message(
      user: { id: user_id, email: "msp-admin@example.com", account_id: account_id, is_admin: true },
      account: { id: account_id, parent_account_id: nil },
      organization: { id: organization_id },
      groups: [
        { id: users_group_id, name: "Users" },
        { id: admins_group_id, name: "Admins" }
      ],
      msp_admin: true
    )

    expect { worker.process(msg) }.to change(CapabilityGrant, :count).by(12)
    expect(
      CapabilityGrant.exists?(
        user_id: user_id,
        permission: "msp.admin.users",
        scope_type: "Organization",
        scope_id: organization_id
      )
    ).to be(true)
  end

  it "fails malformed events before insert_all can bypass model validations" do
    msg = message(
      user: { id: user_id, email: "user@example.com", account_id: account_id, is_admin: false },
      account: { id: account_id, parent_account_id: nil },
      organization: { id: organization_id },
      groups: [
        { id: nil, name: "Users" }
      ]
    )

    expect { worker.process(msg) }.not_to change(CapabilityGrant, :count)
    expect(worker).not_to have_received(:delete)
  end

  def message(user:, account:, organization:, groups:, msp_admin: false)
    FakeMessage.new(
      JSON.dump(
        type: "demo.user.create",
        user: user,
        account: account,
        organization: organization,
        groups: groups,
        msp_admin: msp_admin
      ),
      SecureRandom.uuid
    )
  end
end
