#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
ruby scripts/check_stack_ports.rb
ruby scripts/check_production_config.rb
mkdir -p data/production/demo-fixtures
apps=(user-service account-service authorization-service organization-service group-service user-management-service)
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  ./dc_prod build "${apps[@]}"
fi
services="$(./dc_prod config --services)"
mapfile -t databases < <(printf '%s\n' "$services" | ruby -ne 'puts $_ if /-db(?:-|$)/')
./dc_prod up -d --wait --remove-orphans "${databases[@]}" accountcache authcache orgcache groupcache otel-collector jaeger eventstream
# Prepare schemas before booting consumers; never reset existing data.
for service in "${apps[@]}"; do
  ./dc_prod run --rm --no-deps "$service" bin/rails db:prepare
done
./dc_prod up -d --no-deps "${apps[@]}" account-auth-service
for service in "${apps[@]}" account-auth-service; do
  ready=0
  for ((attempt=0; attempt<90; attempt++)); do
    if ./dc_prod exec -T "$service" curl -fsS --max-time 2 http://localhost:3000/up >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! ./dc_prod ps --status running --services | rg -Fxq "$service"; then
      echo "Production service exited before readiness: $service" >&2
      ./dc_prod logs --no-color --tail 100 "$service" >&2
      exit 1
    fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    echo "Production service failed readiness: $service" >&2
    ./dc_prod logs --no-color --tail 100 "$service" >&2
    exit 1
  fi
done
echo 'Production applications ready. Populate production fixtures before article collection; see BENCHMARK_PLAN.md.'
