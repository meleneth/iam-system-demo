#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir="$PWD"
./dc_test up -d authz-db organization-db account-db user-db group-db authcache
services=(authorization-service organization-service account-service user-service group-service)
for service in "${services[@]}"; do
  ./dc_test run --rm --no-deps "$service" bin/rails db:prepare
  ./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" -e "AUTHORIZATION_FIXTURE_SERVICE=$service" "$service" bin/rails runner /workspace/test/integration/authorization_fixture.rb
done
./dc_test run --rm --no-deps authorization-service bundle exec ruby -rredis -e '
  (1..4).each do |db|
    redis = Redis.new(url: "redis://authcache:6379/#{db}")
    redis.scan_each(match: "*a1700000-0000-4000-8000-*").each { |key| redis.del(key) }
  end
'
services+=(user-management-service account-auth-service group-auth-service organization-auth-service)
containers=()
cleanup() {
  if ((${#containers[@]})); then docker stop "${containers[@]}" >/dev/null; fi
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
  container=$(./dc_test run --rm --no-deps --use-aliases -d \
    -e RAILS_ENV=test \
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
./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" authorization-service bundle exec rspec /workspace/test/integration/authorization_boundary_spec.rb --format documentation
./dc_test run --rm --no-deps -v "$repo_dir:/workspace:ro" authorization-service bundle exec ruby /workspace/test/integration/authorization_smoke_benchmark.rb
