require "rails_helper"
require Rails.root.join("app/workers/organization_create_queue_worker")
require "json"
require "securerandom"

RSpec.describe OrganizationCreateQueueWorker do
  FakeMessage = Struct.new(:body, :receipt_handle)

  let(:worker) { described_class.new(queue_url: "http://example.test/organization_create") }
  let(:organization_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:msp_organization_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }

  before do
    allow(worker).to receive(:delete)
  end

  it "idempotently projects MSP organization mappings from duplicate user-create events" do
    Organization.create!(id: msp_organization_id)
    OrganizationAccount.create!(organization_id: msp_organization_id, account_id: msp_account_id)

    msg = FakeMessage.new(
      JSON.dump(
        type: "demo.user.create",
        user: { id: SecureRandom.uuid, account_id: account_id, is_admin: false },
        account: { id: account_id, parent_account_id: nil },
        organization: { id: organization_id },
        groups: [],
        msp_managed_by_organization_id: msp_organization_id,
        msp_account_id: msp_account_id
      ),
      SecureRandom.uuid
    )

    expect { worker.process(msg) }.to change(MspManagedOrganization, :count).by(1)
    expect { worker.process(msg) }.not_to change(MspManagedOrganization, :count)
    expect(
      MspManagedOrganization.where(
        msp_organization_id: msp_organization_id,
        msp_account_id: msp_account_id,
        client_organization_id: organization_id
      )
    ).to exist
    expect(worker).to have_received(:delete).twice
  end

  it "projects MSP organization mappings when client messages arrive before the MSP admin account message" do
    msg = FakeMessage.new(
      JSON.dump(
        type: "demo.user.create",
        user: { id: SecureRandom.uuid, account_id: account_id, is_admin: false },
        account: { id: account_id, parent_account_id: nil },
        organization: { id: organization_id },
        groups: [],
        msp_managed_by_organization_id: msp_organization_id,
        msp_account_id: msp_account_id
      ),
      SecureRandom.uuid
    )

    expect { worker.process(msg) }
      .to change(MspManagedOrganization, :count).by(1)
      .and change(Organization, :count).by(2)
      .and change(OrganizationAccount, :count).by(2)

    expect(
      OrganizationAccount.where(
        organization_id: msp_organization_id,
        account_id: msp_account_id
      )
    ).to exist
    expect(worker).to have_received(:delete)
  end
end
