require "rails_helper"

RSpec.describe OrganizationAccount do
  around { |example| AuthorizationContext.as_iam { example.run } }

  it "cannot assign one account to two unrelated organizations or project it twice" do
    organizations = Array.new(2) { Organization.create! }
    account_id = SecureRandom.uuid
    row = OrganizationAccount.create!(organization: organizations.first, account_id: account_id)
    expect(OrganizationAccount.new(organization: organizations.last, account_id: account_id)).not_to be_valid
    expect do
      OrganizationAccount.insert_all!([{id: SecureRandom.uuid, organization_id: organizations.last.id, account_id: account_id, created_at: Time.current, updated_at: Time.current}])
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
