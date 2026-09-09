#!/usr/bin/env bash
set -euo pipefail

# Refresh planner statistics after seeding, outside measured benchmark requests.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
stack="${1:-dev}"
case "$stack" in
  dev|test|prod) wrapper="./dc_$stack" ;;
  *) echo "Usage: $0 [dev|test|prod]" >&2; exit 2 ;;
esac

services="$($wrapper config --services)"
for service in $services; do
  case "$service" in
    *-db|*-db-*)
      echo "Analyzing databases in $service ($stack)..."
      "$wrapper" exec -T "$service" sh -s <<'SQL_SH'
set -eu
# Get the list before entering the loop so a failed connection cannot look like
# an empty, successful ANALYZE run. Database names are passed as arguments.
databases=$(psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -Atc \
  'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname')
printf '%s\n' "$databases" | while IFS= read -r database; do
  [ -n "$database" ] || continue
  printf '  %s\n' "$database"
  psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$database" -c 'ANALYZE;'
done
SQL_SH
      ;;
  esac
done
