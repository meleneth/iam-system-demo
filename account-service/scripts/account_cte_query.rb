accounts = Arel::Table.new(:accounts)

# Base query
base_query = accounts
  .project(
    accounts[:id],
    Arel.sql("0 AS level"),
    accounts[:name],
    Arel.sql("ARRAY[name] AS name_path")
  )
  .where(accounts[:parent_account_id].eq(nil))

# Recursive part — use raw SQL fragments for the CTE recursion
recursive_sql = <<~SQL
  SELECT a.id, t0.level + 1, a.name, ARRAY_APPEND(t0.name_path, a.name)
  FROM accounts a
  INNER JOIN account_hierarchy t0 ON t0.id = a.parent_account_id
SQL

# Final SQL
full_sql = <<~SQL
  WITH RECURSIVE account_hierarchy(id, level, name, name_path) AS (
    #{base_query.to_sql}
    UNION ALL
    #{recursive_sql}
  )
  SELECT id, level, name_path[1] AS category, ARRAY_TO_STRING(name_path, ' > ')
  FROM account_hierarchy
SQL

puts "--- Full Query SQL ---"
puts full_sql
puts "--- End Full Query SQL ---"

results =  ActiveRecord::Base.connection.execute(full_sql).map { |row| row }
ap results.last(10)

last_result = results[-1]

puts "Fetching OrgAccount for account #{last_result["id"]}"

org_id = nil
OrganizationAccount.with_headers("pad-user-id" => "IAM_SYSTEM") do
  org_account = OrganizationAccount.find(:first, params: {account_id: last_result["id"]})
  org_id = org_account.organization_id
  puts "Looked up #{org_account.account_id} got #{org_account.organization_id}"
end

organization = nil
Organization.with_headers("pad-user-id" => "IAM_SYSTEM") do
  organization = Organization.find(org_id)
end

puts "Found Organization #{organization.id}"

accounts = []
Organization.with_headers("pad-user-id" => "IAM_SYSTEM") do
  OrganizationAccount.with_headers("pad-user-id" => "IAM_SYSTEM") do
    accounts = organization.accounts
  end
end

toplevel_accounts = accounts.filter { |account| account.parent_account_id == nil}

def find_admin_user(organization, toplevel_accounts)
  User.with_headers("pad-user-id" => "IAM_SYSTEM") do
    toplevel_accounts.each do |account|
      puts "Checking account #{account.id}"
      account.users.each do |user|
        return user if user.can( "Organization", "organization.accounts.create", organization.id)
      end
    end
  end
end

admin_user = find_admin_user(organization, toplevel_accounts)
puts "Admin user is #{admin_user.id}"
puts "go to /accounts/#{last_result["id"]}?as=#{admin_user.id}"
