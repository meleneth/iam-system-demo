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

results =  ActiveRecord::Base.connection.execute(full_sql).map { |row| row }
ap results.last(10)

last_result = results[-1]

puts "Fetching OrgAccount for account #{last_result["id"]}"

org_id = nil
OrganizationAccount.with_headers("pad-user-id" => "IAM_SYSTEM") do
  org_account = OrganizationAccount.find(:first, params: {account_id: last_result["id"]})
  org_id = org_account.organization_id
end

puts "Fetching CapabilityGrant"
CapabilityGrant.with_headers("pad-user-id" => "IAM_SYSTEM") do
  grant = CapabilityGrant.find(:first, params: {
      permission: "organization.accounts.create",
      scope_type: "Organization",
      scope_id: org_id
  })
  puts "User id for org account admin is #{grant.user_id}"
  puts "http://moxie.sectorfour:7500/accounts/#{last_result["id"]}?as=#{grant.user_id}"
end

