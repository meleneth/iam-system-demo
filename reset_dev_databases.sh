#!/usr/bin/env bash
set -euo pipefail

COMPOSE=(docker compose --env-file development.env -f development-compose.yml -f development-overrides.yml)
DB_DIRS=(
  data/development/user-db
  data/development/account-db
  data/development/authz-db
  data/development/organization-db
  data/development/group-db
)
DB_SERVICES=(
  user-db
  account-db
  authz-db
  organization-db
  group-db
)
APP_SERVICES=(
  user-service
  account-service
  authorization-service
  organization-service
  group-service
)
MAX_PREPARE_ATTEMPTS="${MAX_PREPARE_ATTEMPTS:-8}"
PREPARE_RETRY_SLEEP_SECONDS="${PREPARE_RETRY_SLEEP_SECONDS:-5}"
DB_HEALTH_TIMEOUT_SECONDS="${DB_HEALTH_TIMEOUT_SECONDS:-120}"

wait_for_healthy() {
  local service="$1"
  local start
  start="$(date +%s)"

  echo "Waiting for $service to become healthy..."
  while true; do
    local health
    health="$("${COMPOSE[@]}" ps --format json "$service" | ruby -rjson -e 'rows = STDIN.read.lines.map { |line| JSON.parse(line) }; puts(rows.dig(0, "Health") || rows.dig(0, "State") || "missing")')"

    if [[ "$health" == "healthy" ]]; then
      echo "$service is healthy."
      return 0
    fi

    if (( "$(date +%s)" - start >= DB_HEALTH_TIMEOUT_SECONDS )); then
      echo "$service did not become healthy within ${DB_HEALTH_TIMEOUT_SECONDS}s; last status: $health" >&2
      "${COMPOSE[@]}" ps "$service" >&2
      "${COMPOSE[@]}" logs --tail=100 "$service" >&2
      return 1
    fi

    sleep 2
  done
}

run_db_prepare() {
  local service="$1"
  local attempt=1

  while true; do
    echo "Preparing $service... attempt $attempt/$MAX_PREPARE_ATTEMPTS"
    if "${COMPOSE[@]}" run --rm "$service" bin/rails db:prepare; then
      return 0
    fi

    if [[ "$attempt" -ge "$MAX_PREPARE_ATTEMPTS" ]]; then
      echo "Failed to prepare $service after $MAX_PREPARE_ATTEMPTS attempts." >&2
      return 1
    fi

    attempt=$((attempt + 1))
    echo "$service database was not ready yet; sleeping ${PREPARE_RETRY_SLEEP_SECONDS}s..."
    sleep "$PREPARE_RETRY_SLEEP_SECONDS"
  done
}

echo "Stopping development stack..."
"${COMPOSE[@]}" down --remove-orphans

echo "Deleting development database directories..."
for dir in "${DB_DIRS[@]}"; do
  rm -rf "$dir"
done

echo "Starting database services..."
"${COMPOSE[@]}" up -d "${DB_SERVICES[@]}"

echo "Waiting for database health checks..."
for service in "${DB_SERVICES[@]}"; do
  wait_for_healthy "$service"
done

echo "Preparing Rails databases..."
for service in "${APP_SERVICES[@]}"; do
  run_db_prepare "$service"
done

echo "Starting development stack..."
"${COMPOSE[@]}" up -d

echo "Development databases have been recreated."
