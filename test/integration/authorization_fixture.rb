# Small, independently specified fixture. Loaded only by owning services in the test stack.
module AuthorizationFixture
  NAMES = %i[msp_a msp_b client_a client_b cohort_a cohort_b root_a child_a leaf_a sibling_a root_b admin_a admin_b member_a reader_a reader_b child_reader wrong_permission wrong_scope extra_a group_a group_b membership_a membership_b role_only client_a2 root_a2 mixed_actor provider_root_a provider_root_b provider_admins_a provider_admins_b provider_readers_a child_readers wrong_permissions wrong_scopes mixed_grants exact_group_readers group_reader group_reader_peer nonmember].freeze
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
      {msp_a: %i[provider_root_a cohort_a], msp_b: %i[provider_root_b cohort_b], client_a: %i[root_a child_a leaf_a sibling_a extra_a], client_b: %i[root_b], client_a2: %i[root_a2]}.each do |org, accounts|
        accounts.each { |account| OrganizationAccount.create!(organization_id: id(org), account_id: id(account)) }
      end
      %i[a b].each { |side| MspManagedOrganization.create!(msp_organization_id: id("msp_#{side}".to_sym), msp_account_id: id("cohort_#{side}".to_sym), client_organization_id: id("client_#{side}".to_sym)) }
      MspManagedOrganization.create!(msp_organization_id: id(:msp_a), msp_account_id: id(:cohort_a), client_organization_id: id(:client_a2))
    when "account-service"
      Account.where(id: ids).delete_all
      {provider_root_a: nil, provider_root_b: nil, cohort_a: :provider_root_a, cohort_b: :provider_root_b, root_a: nil, child_a: :root_a, leaf_a: :child_a, sibling_a: :root_a, extra_a: nil, root_b: nil, root_a2: nil}.each do |key, parent|
        Account.create!(id: id(key), name: key.to_s, parent_account_id: parent && id(parent))
      end
    when "authorization-service"
      CapabilityGrant.where(group_id: ids).delete_all
      grant = ->(group, permission, type, scope) { CapabilityGrant.create!(group_id: id(group), permission: permission, scope_type: type, scope_id: id(scope)) }
      %i[a b].each do |side|
        provider_group, msp, provider_root, reader_group, client, root = ["provider_admins_#{side}", "msp_#{side}", "provider_root_#{side}", "group_#{side}", "client_#{side}", "root_#{side}"].map(&:to_sym)
        grant.call(provider_group, "organization.accounts.create", "Organization", msp)
        %w[organization.read organization.read.accounts].each { |p| grant.call(provider_group, p, "Organization", msp); grant.call(reader_group, p, "Organization", client) }
        %w[account.read account.users.read].each { |p| grant.call(provider_group, p, "Account", provider_root); grant.call(reader_group, p, "Account", root) }
      end
      %w[account.read account.users.read].each { |p| grant.call(:child_readers, p, "Account", :child_a) }
      grant.call(:wrong_permissions, "account.read", "Account", :root_a)
      grant.call(:wrong_permissions, "account.users.create", "Account", :root_a)
      grant.call(:wrong_scopes, "account.users.read", "Organization", :root_a)
      grant.call(:mixed_grants, "organization.read", "Organization", :msp_a)
      grant.call(:mixed_grants, "account.users.read", "Account", :cohort_b)
      grant.call(:provider_readers_a, "account.read", "Account", :cohort_a)
      grant.call(:exact_group_readers, "group.read", "Group", :group_a)
    when "user-service"
      User.where(id: ids).delete_all
      {admin_a: :cohort_a, admin_b: :cohort_b, member_a: :cohort_a, reader_a: :root_a, child_reader: :child_a, reader_b: :root_b}.each do |user, account|
        User.create!(id: id(user), account_id: id(account), email: "#{user}@authorization.test")
      end
    when "group-service"
      GroupUser.where(group_id: ids).delete_all
      Group.where(id: ids).delete_all
      owners = {group_a: :root_a, group_b: :root_b, provider_admins_a: :provider_root_a, provider_admins_b: :cohort_b,
                provider_readers_a: :cohort_a, child_readers: :child_a, wrong_permissions: :root_a,
                wrong_scopes: :root_a, mixed_grants: :cohort_b, exact_group_readers: :root_a}
      owners.each { |group, account| Group.create!(id: id(group), account_id: id(account), name: group.to_s) }
      memberships = {reader_a: :group_a, reader_b: :group_b, admin_a: :provider_admins_a, admin_b: :provider_admins_b,
                     member_a: :provider_readers_a, child_reader: :child_readers, wrong_permission: :wrong_permissions,
                     wrong_scope: :wrong_scopes, mixed_actor: :mixed_grants, group_reader: :exact_group_readers,
                     group_reader_peer: :exact_group_readers}
      memberships.each_with_index do |(actor, group), index|
        membership_id = actor == :reader_a ? id(:membership_a) : actor == :reader_b ? id(:membership_b) : format("a1700000-0000-4000-8000-%012d", 1000 + index)
        GroupUser.create!(id: membership_id, group_id: id(group), user_id: id(actor))
      end
    else
      raise "Unknown fixture service #{service}"
    end
  end
end
AuthorizationFixture.seed!(ENV.fetch("AUTHORIZATION_FIXTURE_SERVICE")) if ENV.key?("AUTHORIZATION_FIXTURE_SERVICE")
