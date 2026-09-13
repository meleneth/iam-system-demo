# Small, independently specified fixture. Loaded only by owning services in the test stack.
module AuthorizationFixture
  NAMES = %i[msp_a msp_b client_a client_b cohort_a cohort_b root_a child_a leaf_a sibling_a root_b admin_a admin_b member_a reader_a reader_b child_reader wrong_permission wrong_scope extra_a group_a group_b membership_a membership_b role_only client_a2 root_a2 mixed_actor].freeze
  IDS = NAMES.each_with_index.to_h { |name, i| [name, "a1700000-0000-4000-8000-#{format('%012d', i + 1)}"] }.freeze
  def self.id(name) = IDS.fetch(name)
  def self.seed!(service)
    raise "test database required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
    ids = IDS.values
    case service
    when "organization-service"
      MspManagedOrganization.where(msp_organization_id: ids).delete_all
      OrganizationAccount.where(account_id: ids).delete_all
      Organization.where(id: ids).delete_all
      %i[msp_a msp_b client_a client_b client_a2].each { |key| Organization.create!(id: id(key), name: key.to_s) }
      {msp_a: %i[cohort_a], msp_b: %i[cohort_b], client_a: %i[root_a child_a leaf_a sibling_a extra_a], client_b: %i[root_b], client_a2: %i[root_a2]}.each do |org, accounts|
        accounts.each { |account| OrganizationAccount.create!(organization_id: id(org), account_id: id(account)) }
      end
      %i[a b].each { |side| MspManagedOrganization.create!(msp_organization_id: id("msp_#{side}".to_sym), msp_account_id: id("cohort_#{side}".to_sym), client_organization_id: id("client_#{side}".to_sym)) }
      MspManagedOrganization.create!(msp_organization_id: id(:msp_a), msp_account_id: id(:cohort_a), client_organization_id: id(:client_a2))
    when "account-service"
      Account.where(id: ids).delete_all
      {cohort_a: nil, cohort_b: nil, root_a: nil, child_a: :root_a, leaf_a: :child_a, sibling_a: :root_a, extra_a: nil, root_b: nil, root_a2: nil}.each do |key, parent|
        Account.create!(id: id(key), name: key.to_s, parent_account_id: parent && id(parent))
      end
    when "authorization-service"
      CapabilityGrant.where(user_id: ids).delete_all
      grant = ->(actor, permission, type, scope) { CapabilityGrant.create!(user_id: id(actor), permission: permission, scope_type: type, scope_id: id(scope)) }
      %i[a b].each do |side|
        admin, msp, cohort, reader, client, root = ["admin_#{side}", "msp_#{side}", "cohort_#{side}", "reader_#{side}", "client_#{side}", "root_#{side}"].map(&:to_sym)
        grant.call(admin, "msp.admin.users", "Organization", msp)
        grant.call(admin, "organization.accounts.create", "Organization", msp)
        %w[organization.read organization.read.accounts].each { |p| grant.call(admin, p, "Organization", msp); grant.call(reader, p, "Organization", client) }
        %w[account.read account.users.read].each { |p| grant.call(admin, p, "Account", cohort); grant.call(reader, p, "Account", root) }
      end
      %w[account.read account.users.read].each { |p| grant.call(:child_reader, p, "Account", :child_a) }
      grant.call(:wrong_permission, "account.read", "Account", :root_a)
      grant.call(:wrong_permission, "account.users.create", "Account", :root_a)
      grant.call(:wrong_scope, "account.users.read", "Organization", :root_a)
      grant.call(:mixed_actor, "msp.admin.users", "Organization", :msp_a)
      grant.call(:mixed_actor, "account.users.read", "Account", :cohort_b)
      grant.call(:role_only, "msp.admin.users", "Organization", :msp_a)
      grant.call(:member_a, "account.read", "Account", :cohort_a)
    when "user-service"
      User.where(id: ids).delete_all
      {admin_a: :cohort_a, admin_b: :cohort_b, member_a: :cohort_a, reader_a: :root_a, child_reader: :child_a, reader_b: :root_b}.each do |user, account|
        User.create!(id: id(user), account_id: id(account), email: "#{user}@authorization.test")
      end
    when "group-service"
      GroupUser.where(id: ids).delete_all
      Group.where(id: ids).delete_all
      %i[a b].each do |side|
        Group.create!(id: id("group_#{side}".to_sym), account_id: id("root_#{side}".to_sym), name: "group_#{side}")
        GroupUser.create!(id: id("membership_#{side}".to_sym), group_id: id("group_#{side}".to_sym), user_id: id("reader_#{side}".to_sym))
      end
    else
      raise "Unknown fixture service #{service}"
    end
  end
end
AuthorizationFixture.seed!(ENV.fetch("AUTHORIZATION_FIXTURE_SERVICE")) if ENV.key?("AUTHORIZATION_FIXTURE_SERVICE")
