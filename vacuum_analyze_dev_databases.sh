#!/usr/bin/env bash
set -euo pipefail

COMPOSE=(docker compose --env-file development.env -f development-compose.yml -f development-overrides.yml)

run_vacuum_analyze() {
  local service="$1"
  local user_var="$2"
  local db_var="$3"
  local user="${!user_var}"
  local db="${!db_var}"

  echo "Running VACUUM ANALYZE on $db via $service..."
  "${COMPOSE[@]}" exec -T "$service" psql -U "$user" -d "$db" -c "VACUUM ANALYZE;"
}

set -a
source development.env
set +a

run_vacuum_analyze user-db USER_DB_POSTGRES_USER USER_DB_POSTGRES_DB
run_vacuum_analyze account-db ACCOUNT_DB_POSTGRES_USER ACCOUNT_DB_POSTGRES_DB
run_vacuum_analyze authz-db AUTHZ_DB_POSTGRES_USER AUTHZ_DB_POSTGRES_DB
run_vacuum_analyze organization-db ORGANIZATION_DB_POSTGRES_USER ORGANIZATION_DB_POSTGRES_DB
run_vacuum_analyze group-db GROUP_DB_POSTGRES_USER GROUP_DB_POSTGRES_DB

echo "VACUUM ANALYZE complete for all development databases."
