#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir="$PWD"
: "${AUTHORIZATION_CHECK_MODE:?set can or capabilities}"
: "${GLOBAL_IAM_DEMO_USE_REDIS:?set true or false}"
export AUTHORIZATION_CHECK_MODE GLOBAL_IAM_DEMO_USE_REDIS
proof_output="${PROOF_OUTPUT:-$repo_dir/reports/raw/record-authorization/$AUTHORIZATION_CHECK_MODE-$GLOBAL_IAM_DEMO_USE_REDIS}"
mkdir -p "$proof_output"
proof_output=$(realpath "$proof_output")
# Each run owns fresh evidence, including requests from failing examples.
: > "$proof_output/requests.jsonl"
rspec_options=()
if [[ -n "${PROOF_EXAMPLE:-}" ]]; then rspec_options+=(--example-matches "$PROOF_EXAMPLE"); fi
./dc_test up -d authz-db organization-db account-db user-db group-db authcache
services=(authorization-service organization-service account-service user-service group-service)
if [[ "${PROOF_SKIP_SEED:-0}" != 1 ]]; then
for service in "${services[@]}"; do
  ./dc_test run --rm --no-deps "$service" bin/rails db:prepare
  ./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" -e "AUTHORIZATION_FIXTURE_SERVICE=$service" "$service" bin/rails runner /workspace/test/integration/authorization_fixture.rb
  ./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" -e "RECORD_AUTHORIZATION_FIXTURE_SERVICE=$service" "$service" bin/rails runner /workspace/test/integration/record_authorization_fixture.rb
done
fi
./dc_test run --rm --no-deps authorization-service bundle exec ruby -rredis -e '
  (1..4).each do |db|
    redis = Redis.new(url: "redis://authcache:6379/#{db}")
    redis.scan_each(match: "*a17[01]0000*").each { |key| redis.del(key) }
  end
'
if [[ "${PROOF_SKIP_ROUTES:-0}" != 1 ]]; then
for service in "${services[@]}" user-management-service; do
  ./dc_test run --rm --no-deps -T -v "$repo_dir:/workspace:ro" -v "$proof_output:/evidence" \
    -e "PROOF_ROUTE_SERVICE=$service" "$service" bin/rails runner /workspace/test/integration/record_authorization_routes.rb
done
fi
services+=(user-management-service account-auth-service group-auth-service organization-auth-service)
containers=()
server_lifecycle=(--rm)
sampler_options=()
if [[ "${PROOF_MUTATION_DRIVER:-0}" == 1 ]]; then server_lifecycle=(); fi
if [[ "${PROOF_MUTATION_DRIVER:-0}" == 1 || "${PROOF_TRACE_DRIVER:-0}" == 1 ]]; then
  sampler_options=(-e OTEL_TRACES_SAMPLER=parentbased_traceidratio -e OTEL_TRACES_SAMPLER_ARG=0.0)
fi
cleanup() {
  if ((${#containers[@]})); then
    docker stop "${containers[@]}" >/dev/null || true
    if [[ "${PROOF_MUTATION_DRIVER:-0}" == 1 ]]; then docker rm "${containers[@]}" >/dev/null || true; fi
  fi
}
trap cleanup EXIT
for service in "${services[@]}"; do
  account_url=http://account-service:80
  group_url=http://group-service:80
  organization_url=http://organization-service:80
  if [[ "$service" == authorization-service ]]; then
    account_url=http://account-auth-service:80
    group_url=http://group-auth-service:80
    organization_url=http://organization-auth-service:80
  elif [[ "$service" == account-auth-service ]]; then
    organization_url=http://organization-auth-service:80
  fi
  container=$(./dc_test run "${server_lifecycle[@]}" --no-deps --use-aliases -d "${sampler_options[@]}" \
    -e RAILS_ENV=test \
    -e "AUTHORIZATION_CHECK_MODE=$AUTHORIZATION_CHECK_MODE" \
    -e OTEL_TRACES_EXPORTER=none \
    -e "GLOBAL_IAM_DEMO_USE_REDIS=${GLOBAL_IAM_DEMO_USE_REDIS:-false}" \
    -e "ACCOUNT_SERVICE_API_BASE_URL=$account_url" \
    -e "ORGANIZATION_SERVICE_API_BASE_URL=$organization_url" \
    -e "GROUP_SERVICE_API_BASE_URL=$group_url" \
    -e ACCOUNT_CACHE_REDIS_URL=redis://authcache:6379/2 \
    -e ORGANIZATION_CACHE_REDIS_URL=redis://authcache:6379/3 \
    -e GROUP_CACHE_REDIS_URL=redis://authcache:6379/4 \
    "$service" bin/rails server -b 0.0.0.0 -p 80 -P /tmp/authorization-correctness.pid)
  containers+=("$container")
done
./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" authorization-service ruby -rnet/http -e '
  ARGV.each do |service|
    60.times do |attempt|
      begin
        break if Net::HTTP.get_response(URI("http://#{service}:80/up")).code == "200"
      rescue StandardError
      end
      raise "#{service} failed to start" if attempt == 59
      sleep 1
    end
  end
' "${services[@]}"
if [[ "${PROOF_TRACE_DRIVER:-0}" == 1 ]]; then
  ./dc_test run --rm --no-deps -T -v "$repo_dir:/workspace:ro" -v "$proof_output:/evidence" \
    -e "AUTHORIZATION_CHECK_MODE=$AUTHORIZATION_CHECK_MODE" -e "GLOBAL_IAM_DEMO_USE_REDIS=$GLOBAL_IAM_DEMO_USE_REDIS" \
    -e "PROOF_SOURCE_REVISION=$(git rev-parse HEAD)" \
    authorization-service bundle exec ruby /workspace/test/integration/record_authorization_traces.rb
  exit
fi
if [[ "${PROOF_MUTATION_DRIVER:-0}" == 1 ]]; then
  : > "$proof_output/containers.txt"
  for index in "${!services[@]}"; do
    printf '%s %s\n' "${services[$index]}" "${containers[$index]}" >> "$proof_output/containers.txt"
  done
  python3 scripts/test_record_authorization_mutations.py --running-profile
  exit
fi
./dc_test run --rm --no-deps -T -v "$repo_dir:/workspace:ro" -v "$proof_output:/evidence" \
  -e "AUTHORIZATION_CHECK_MODE=$AUTHORIZATION_CHECK_MODE" -e "GLOBAL_IAM_DEMO_USE_REDIS=$GLOBAL_IAM_DEMO_USE_REDIS" \
  -e PROOF_LEDGER=/evidence/requests.jsonl \
  authorization-service bundle exec rspec /workspace/test/integration/record_authorization_spec.rb \
  --format documentation --format json --out /evidence/results.json "${rspec_options[@]}"
python3 - "$proof_output/results.json" <<'PY_CHECK'
import json, sys
report = json.load(open(sys.argv[1]))
assert report['summary']['example_count'] > 0, 'No proof examples executed'
assert report['summary']['pending_count'] == 0, 'Pending proof examples invalidate the run'
PY_CHECK
if [[ "${PROOF_SKIP_EXISTING:-0}" != 1 ]]; then
  ./dc_test run --rm --no-deps -T -v "$repo_dir:/workspace:ro" -v "$proof_output:/evidence" \
    -e "AUTHORIZATION_CHECK_MODE=$AUTHORIZATION_CHECK_MODE" \
    authorization-service bundle exec rspec /workspace/test/integration/authorization_boundary_spec.rb \
    --format documentation --format json --out /evidence/existing-results.json
fi
