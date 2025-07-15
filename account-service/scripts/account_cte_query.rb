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

ap ActiveRecord::Base.connection.execute(full_sql).map { |row| row }
