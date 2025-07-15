account_org_map = {}         # account_id => organization_id
existing_accounts = []

100000.times do |i|
  Instrumentation.trace("demo.user.create", attributes: { index: i }) do
    account = nil
    organization = nil

    # 20% chance to reuse an existing account
    if existing_accounts.any? && rand < 0.20
      account = existing_accounts.sample
      org_id = account_org_map[account.id]
    else
      # 20% chance to create a child account
      if existing_accounts.any? && rand < 0.20
        parent_account = existing_accounts.sample
        parent_org_id = account_org_map[parent_account.id]

        account = Account.create(parent_account_id: parent_account.id)
        OrganizationAccount.create!(organization_id: parent_org_id, account_id: account.id)
        org_id = parent_org_id
      else
        organization = Organization.create
        account = Account.create
        OrganizationAccount.create!(organization_id: organization.id, account_id: account.id)
        org_id = organization.id
      end

      existing_accounts << account
      account_org_map[account.id] = org_id
    end

    email = "user#{SecureRandom.hex(4)}@example.com"
    user = User.create(email: email, account_id: account.id)
    print "."
    #ap account.instance_variable_get(:@attributes)
    #ap user.instance_variable_get(:@attributes)
  end
end
