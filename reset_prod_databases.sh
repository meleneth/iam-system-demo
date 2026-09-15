#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

apps=(user-service account-service authorization-service organization-service group-service user-management-service)
auth_services=(account-auth-service group-auth-service organization-auth-service)

ruby scripts/check_production_config.rb
mapfile -t services < <(./dc_prod config --services)
mapfile -t databases < <(printf '%s\n' "${services[@]}" | ruby -ne 'puts $_ if /-db(?:-|$)/')
mapfile -t workers < <(printf '%s\n' "${services[@]}" | ruby -ne 'puts $_ if /-create-service-worker-/')

[[ "${#databases[@]}" -eq 20 ]] || {
  echo "Expected 20 production PostgreSQL services, found ${#databases[@]}" >&2
  exit 1
}
[[ "${#workers[@]}" -eq 10 ]] || {
  echo "Expected 10 production worker services, found ${#workers[@]}" >&2
  exit 1
}

echo 'Stopping production applications and seed workers...'
./dc_prod stop "${apps[@]}" "${auth_services[@]}" "${workers[@]}"

echo 'Starting production database and cache services...'
./dc_prod up -d --wait "${databases[@]}" accountcache authcache orgcache groupcache

for database in "${databases[@]}"; do
  echo "Truncating $database..."
  ./dc_prod exec -T "$database" sh -c 'psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' <<'SQL'
DO $truncate$
DECLARE
  table_name text;
BEGIN
  FOR table_name IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
  LOOP
    EXECUTE format('TRUNCATE TABLE public.%I RESTART IDENTITY CASCADE', table_name);
  END LOOP;
END
$truncate$;
SQL
done

echo 'Truncating User Management SQLite databases...'
./dc_prod run --rm --no-deps user-management-service bin/rails runner - <<'RUBY'
class ProductionResetRecord < ActiveRecord::Base
  self.abstract_class = true
end

ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |configuration|
  ProductionResetRecord.establish_connection(configuration)
  connection = ProductionResetRecord.connection
  tables = connection.tables - %w[ar_internal_metadata schema_migrations]
  connection.transaction do
    connection.disable_referential_integrity do
      tables.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
    end
  end
  ProductionResetRecord.remove_connection
  puts "#{configuration.name}: truncated #{tables.length} tables"
end
RUBY

for cache in accountcache authcache orgcache groupcache; do
  echo "Clearing $cache..."
  ./dc_prod exec -T "$cache" redis-cli FLUSHALL >/dev/null
done

echo 'Recreating the in-memory event broker...'
./dc_prod up -d --force-recreate eventstream

echo 'Production databases, caches, and seed queues are empty.'
