# Dedicated test-only graph. Expected access is specified separately in the spec;
# never ask the implementation under test to calculate expected scope coverage.
require 'digest'
module RecordAuthorizationFixture
  PREFIX = 'a1710000'
  def self.id(name)
    "#{PREFIX}-0000-4000-8000-#{Digest::SHA256.hexdigest(name.to_s)[0, 12]}"
  end
  PARENTS = {empty: nil, root: nil, child: :root, leaf: :child, sibling: :root, detached: nil,
             foreign: nil, second_client: nil, provider_root: nil, provider: :provider_root,
             foreign_provider: nil}.freeze
  ORGANIZATIONS = {empty_org: [:empty], client: %i[root child leaf sibling detached], other_client: [:foreign],
                   client_two: [:second_client], provider_org: %i[provider_root provider],
                   other_provider_org: [:foreign_provider]}.freeze
  PERMISSIONS = {read: 'account.read', users: 'account.users.read', org: 'organization.read',
                 list: 'organization.read.accounts', exact: 'group.read'}.freeze
  # All actors live in foreign_provider. Their location never supplies authority.
  def self.grants
    rows = []
    %i[read users].each do |permission|
      PARENTS.each_key { |scope| rows << ["#{permission}_#{scope}", PERMISSIONS.fetch(permission), 'Account', scope] }
      rows << ["#{permission}_wrong_scope", PERMISSIONS.fetch(permission), 'Organization', :child]
    end
    %i[org list].each do |permission|
      ORGANIZATIONS.each_key { |scope| rows << ["#{permission}_#{scope}", PERMISSIONS.fetch(permission), 'Organization', scope] }
      rows << ["#{permission}_wrong_scope", PERMISSIONS.fetch(permission), 'Account', :client]
    end
    rows << ['group_account', 'group.read', 'Account', :child]
    rows << ['group_wrong_permission', 'group.users.create', 'Group', :group_child]
    rows << ['group_wrong_scope', 'group.read', 'Organization', :child]
    %w[read_list read_org list_org].each do |actor|
      rows << [actor, 'account.read', 'Account', :child] if actor.start_with?('read')
      rows << [actor, 'organization.read.accounts', 'Organization', :client] if actor.include?('list')
      rows << [actor, 'organization.read', 'Organization', :client] if actor.include?('org')
    end
    rows << ['internal_admin', 'organization.accounts.create', 'Organization', :client]
    rows << ['exact_child', 'group.read', 'Group', :group_child]
    rows << ['exact_child', 'group.users.create', 'Group', :group_child]
    rows << ['mixed', 'group.read', 'Group', :group_child]
    rows << ['mixed', 'account.users.read', 'Account', :sibling]
    %w[account.read account.users.read].each { |p| rows << ['full', p, 'Account', :provider_root] }
    %w[organization.read organization.read.accounts].each { |p| rows << ['full', p, 'Organization', :client] }
    rows += rows.select { |row| row.first == 'full' }.map { |_, *grant| ['nested', *grant] }
    rows << ['nested', 'group.read', 'Group', :group_foreign]
    rows
  end
  def self.actors = (grants.map(&:first) + %w[nonmember peer]).uniq
  def self.seed!(service)
    raise 'isolated test database required' unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?('_test')
    match = "#{PREFIX}%"
    case service
    when 'account-service'
      Account.where('id::text LIKE ?', match).delete_all
      PARENTS.each { |key, parent| Account.create!(id: id(key), name: key.to_s, parent_account_id: parent && id(parent)) }
    when 'organization-service'
      MspManagedOrganization.where('msp_account_id::text LIKE ?', match).delete_all
      OrganizationAccount.where('account_id::text LIKE ?', match).delete_all
      Organization.where('id::text LIKE ?', match).delete_all
      ORGANIZATIONS.each do |org, accounts|
        Organization.create!(id: id(org), name: org.to_s)
        accounts.each { |account| OrganizationAccount.create!(id: id("link_#{account}"), organization_id: id(org), account_id: id(account)) }
      end
      %i[client client_two].each { |client| MspManagedOrganization.create!(msp_organization_id: id(:provider_org), msp_account_id: id(:provider), client_organization_id: id(client)) }
      MspManagedOrganization.create!(msp_organization_id: id(:other_provider_org), msp_account_id: id(:foreign_provider), client_organization_id: id(:other_client))
    when 'user-service'
      User.where('id::text LIKE ?', match).delete_all
      PARENTS.each_key { |key| next if key == :empty; User.create!(id: id("user_#{key}"), account_id: id(key), email: "#{key}@record-proof.test") }
      actors.each { |actor| User.create!(id: id("actor_#{actor}"), account_id: id(:foreign_provider), email: "#{actor}@record-proof.test") }
    when 'group-service'
      GroupUser.where('id::text LIKE ?', match).delete_all
      Group.where('id::text LIKE ?', match).delete_all
      PARENTS.each_key do |key|
        next if key == :empty
        Group.create!(id: id("group_#{key}"), account_id: id(key), name: key.to_s)
        # Membership ownership is the GROUP account, deliberately not the user's.
        GroupUser.create!(id: id("membership_#{key}"), group_id: id("group_#{key}"), user_id: id('actor_nonmember'))
      end
      Group.create!(id: id(:group_child_peer), account_id: id(:child), name: 'child peer')
      GroupUser.create!(id: id(:membership_child_peer), group_id: id(:group_child_peer), user_id: id('actor_nonmember'))
      GroupUser.create!(id: id('cross_membership'), group_id: id(:group_foreign), user_id: id(:user_child))
      grants.map(&:first).uniq.each do |actor|
        Group.create!(id: id("grant_group_#{actor}"), account_id: id(:foreign_provider), name: actor)
        GroupUser.create!(id: id("grant_membership_#{actor}"), group_id: id("grant_group_#{actor}"), user_id: id("actor_#{actor}"))
      end
      GroupUser.create!(id: id('peer_membership'), group_id: id('grant_group_exact_child'), user_id: id('actor_peer'))
    when 'authorization-service'
      CapabilityGrant.where('group_id::text LIKE ?', match).delete_all
      grants.each { |actor, permission, type, scope| CapabilityGrant.create!(group_id: id("grant_group_#{actor}"), permission: permission, scope_type: type, scope_id: id(scope)) }
    else
      raise "unknown service #{service}"
    end
  end
end
RecordAuthorizationFixture.seed!(ENV.fetch('RECORD_AUTHORIZATION_FIXTURE_SERVICE')) if ENV.key?('RECORD_AUTHORIZATION_FIXTURE_SERVICE')
