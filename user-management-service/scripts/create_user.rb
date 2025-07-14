account = nil
user = nil
organization = nil
Instrumentation.trace("demo.user.create", attributes: { score: rand(100) }) do
  organization = Organization.create
  account = Account.create
  org_account = OrganizationAccount.create(organization_id: organization.id, account_id: account.id)
  user = User.create(email: "bleh@example.com", account_id: account.id)
end

ap account.instance_variable_get(:@attributes)
ap user.instance_variable_get(:@attributes)
