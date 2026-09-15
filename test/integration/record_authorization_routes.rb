# Run inside each test Rails application. An added application route must be
# explicitly classified before this proof can pass. Dormant CRUD methods do not
# count as reachable endpoints. Framework diagnostics are not IAM record reads.
require 'json'
service = ENV.fetch('PROOF_ROUTE_SERVICE')
policies = {
  'account-service' => {
    'accounts#index' => 'Account/account.read', 'accounts#search' => 'Account/account.read',
    'accounts#show' => 'Account/account.read', 'accounts#account_with_parents' => 'requested and returned Account/account.read',
    'accounts#accounts_with_parents' => 'requested and returned Account/account.read'
  },
  'user-service' => {
    'users#index' => 'Account/account.users.read', 'users#search' => 'Account/account.users.read',
    'users#show' => 'Account/account.users.read', 'users_counts#index' => 'Account/account.users.read for every requested account'
  },
  'group-service' => {
    'groups#index' => 'Account/account.users.read OR Group/group.read, per returned group',
    'groups#search' => 'Account/account.users.read OR Group/group.read, per returned group',
    'groups#show' => 'Account/account.users.read OR Group/group.read, per returned group',
    'group_users#index' => 'owning group: Account/account.users.read OR Group/group.read',
    'group_users#search' => 'owning group: Account/account.users.read OR Group/group.read',
    'group_users#show' => 'owning group: Account/account.users.read OR Group/group.read',
    'groups_counts#index' => 'Account/account.users.read for every requested account',
    'internal/auth/contexts#memberships' => 'IAM_SYSTEM_AUTH only', 'internal/auth/contexts#groups' => 'IAM_SYSTEM_AUTH only'
  },
  'organization-service' => {
    'organizations#show' => 'Organization/organization.read',
    'organization_accounts#index' => 'Organization/organization.read.accounts OR Account/account.read, per returned relationship',
    'organization_accounts#show' => 'Organization/organization.read.accounts OR Account/account.read, per returned relationship',
    'organization_accounts#for_account' => 'Account/account.read AND Organization/organization.read.accounts AND Organization/organization.read',
    'organization_accounts#for_accounts' => 'Account/account.read AND Organization/organization.read.accounts',
    'organizations/accounts_count#index' => 'Organization/organization.read.accounts',
    'internal/msp_managed_organizations#authorized_show' => 'Account/account.read for provider and every returned managed account',
    'internal/msp_managed_organizations#show' => 'IAM_SYSTEM only',
    'internal/random_records#organization' => 'IAM_SYSTEM only',
    'internal/random_records#organization_account' => 'IAM_SYSTEM only',
    'internal/auth/account_contexts#create' => 'IAM_SYSTEM_AUTH only',
    'internal/auth/account_contexts#providers' => 'IAM_SYSTEM_AUTH only'
  },
  'authorization-service' => {
    'can#index' => 'per-target permission decision',
    'capabilities#account' => 'per-target Account capability list', 'capabilities#accounts' => 'per-target Account capability lists',
    'capabilities#organization' => 'per-target Organization capability list', 'capabilities#organizations' => 'per-target Organization capability lists',
    'capabilities#group' => 'per-target Group capability list', 'capabilities#groups' => 'per-target Group capability lists',
    'internal/admin_users#organization' => 'IAM_SYSTEM only'
  },
  'user-management-service' => {
    'accounts#view' => 'composed downstream record checks, explicit actor',
    'accounts#slow_view' => 'composed downstream record checks, explicit actor',
    'accounts#slowest_view' => 'composed downstream record checks, explicit actor',
    'organization_user_management#partition' => 'composed downstream record checks, explicit actor',
    'frontdoor#random_record_detail' => 'composed downstream record checks, explicit actor',
    'organization_user_management#show' => 'page shell: no record fetch',
    'frontdoor#index' => 'fixture catalog: no service record fetch',
    'frontdoor#demo_query' => 'fixture query text: no service record fetch'
  }
}.fetch(service)
rows = Rails.application.routes.routes.filter_map do |route|
  controller, action = route.defaults.values_at(:controller, :action)
  next unless controller
  next if controller.start_with?('rails/', 'active_storage/', 'action_mailbox/', 'turbo/native/')
  target = "#{controller}##{action}"
  policy = if target == 'graphql#execute'
    service == 'user-management-service' ? 'GraphQL composed downstream checks, field-scoped explicit actor' : 'generator schema: no implemented IAM record loader'
  elsif target == 'metrics#show'
    'operational metrics: no IAM records'
  else
    policies.fetch(target) { raise "UNCLASSIFIED RECORD SURFACE #{service} #{target}" }
  end
  {method: route.verb, path: route.path.spec.to_s, target: target, policy: policy}
end
missing = policies.keys - rows.map { |r| r.fetch(:target) }
raise "Documented routes missing: #{missing}" unless missing.empty?
File.write("/evidence/routes-#{service}.json", JSON.pretty_generate(rows) + "\n")
