# frozen_string_literal: true

# Grants a simulated set of capabilities to a user
class CapabilityGranter
  def initialize(user, account_id, org_id, is_admin)
    @user_id = user.id
    @account_id = account_id
    @org_id = org_id
    @is_admin = is_admin
  end

  def grant!
    CapabilityGrant.create!(user_id: @user_id, permission: "organization.read", scope_type: "Organization", scope_id: @org_id)
    CapabilityGrant.create!(user_id: @user_id, permission: "organization.accounts.read", scope_type: "Organization", scope_id: @org_id)

    if @is_admin
      CapabilityGrant.create!(user_id: @user_id, permission: "organization.accounts.create", scope_type: "Organization", scope_id: @org_id)
      CapabilityGrant.create!(user_id: @user_id, permission: "account.read", scope_type: "Account", scope_id: @account_id)
      CapabilityGrant.create!(user_id: @user_id, permission: "account.users.read", scope_type: "Account", scope_id: @account_id)
      CapabilityGrant.create!(user_id: @user_id, permission: "account.users.create", scope_type: "Account", scope_id: @account_id)
    else
      CapabilityGrant.create!(user_id: @user_id, permission: "account.read", scope_type: "Account", scope_id: @account_id)
      CapabilityGrant.create!(user_id: @user_id, permission: "account.users.read", scope_type: "Account", scope_id: @account_id)
    end
  end
end


# Creates demo users, accounts, organizations, and capability grants
class DemoUserSeeder
  def initialize(count: 1000)
    @count = count
    @account_org_map = {}     # account_id => organization_id
    @existing_accounts = []
  end

  def seed!
    @count.times do |i|
      Instrumentation.trace("demo.user.create", attributes: { index: i }) do
        create_user!
        print "."
      end
    end
  end

  private

  def create_user!
    account = nil
    organization = nil
    is_account_admin = false

    if reuse_existing_account?
      account = @existing_accounts.sample
      org_id = @account_org_map[account.id]
    else
      if create_child_account?
        parent = @existing_accounts.sample
        org_id = @account_org_map[parent.id]
        account = Account.create!(parent_account_id: parent.id)
        OrganizationAccount.create!(organization_id: org_id, account_id: account.id)
        is_account_admin = false
      else
        organization = Organization.create!
        account = Account.create!
        OrganizationAccount.create!(organization_id: organization.id, account_id: account.id)
        org_id = organization.id
        is_account_admin = true
      end

      @existing_accounts << account
      @account_org_map[account.id] = org_id
    end

    user = User.create!(
      email: "user#{SecureRandom.hex(4)}@example.com",
      account_id: account.id
    )

    CapabilityGranter.new(user, account.id, org_id, is_account_admin).grant!
  end

  def reuse_existing_account?
    @existing_accounts.any? && rand < 0.40
  end

  def create_child_account?
    @existing_accounts.any? && rand < 0.40
  end
end

DemoUserSeeder.new(count: 1000).seed!
