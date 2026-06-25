require "rails_helper"
require Rails.root.join("app/workers/organization_create_queue_worker")
require "json"
require "securerandom"

RSpec.describe OrganizationCreateQueueWorker do
  FakeMessage = Struct.new(:body, :receipt_handle)

  let(:worker) { described_class.new(queue_url: "http://example.test/organization_create") }
  let(:organization_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }
  let(:msp_account_id) { SecureRandom.uuid }

  before do
    allow(worker).to receive(:delete)
  end

  it "idempotently projects MSP mappings from duplicate user-create events" do
    msg = FakeMessage.new(
      JSON.dump(
        type: "demo.user.create",
        user: { id: SecureRandom.uuid, account_id: account_id, is_admin: false },
        account: { id: account_id, parent_account_id: nil },
        organization: { id: organization_id },
        groups: [],
        msp_managed_by_account_id: msp_account_id
      ),
      SecureRandom.uuid
    )

    expect { worker.process(msg) }.to change(MspManagedAccount, :count).by(1)
    expect { worker.process(msg) }.not_to change(MspManagedAccount, :count)
    expect(MspManagedAccount.where(msp_account_id: msp_account_id, managed_account_id: account_id)).to exist
    expect(worker).to have_received(:delete).twice
  end
end
