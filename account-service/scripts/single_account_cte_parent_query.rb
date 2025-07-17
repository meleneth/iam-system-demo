starting_account_id = 'c4113a02-a42a-4c73-b836-2c22fb281cbe'
org_account = OrganizationAccount.find(:first, params: { account_id: starting_account_id })
org_accounts = OrganizationAccount.find(:all, params: { organization_id: org_account.organization_id })
seed_ids = org_accounts.map(&:account_id)

accounts = Arel::Table.new(:accounts)

base_query = accounts
  .project(
    accounts[:id],
    accounts[:parent_account_id],
    accounts[:name],
    Arel.sql("0 AS level")
  )
  .where(accounts[:id].eq(starting_account_id))

# Interpolate safe UUID strings
seed_id_list = seed_ids.map { |id| ActiveRecord::Base.connection.quote(id) }.join(', ')

recursive_sql = <<~SQL
  SELECT a.id, a.parent_account_id, a.name, t.level + 1
  FROM accounts a
  INNER JOIN account_ancestry t ON t.parent_account_id = a.id
  WHERE a.id IN (#{seed_id_list})
SQL

final_sql = <<~SQL
  WITH RECURSIVE account_ancestry(id, parent_account_id, name, level) AS (
    #{base_query.to_sql}
    UNION ALL
    #{recursive_sql}
  )
  SELECT *
  FROM account_ancestry
  WHERE id != #{ActiveRecord::Base.connection.quote(starting_account_id)}
  ORDER BY level DESC
SQL

ap ActiveRecord::Base.connection.execute(final_sql).to_a

puts final_sql
