#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${MANIFEST:-data/development/demo-fixtures/latest/fixture_manifest.json}"
OUT_DIR="${OUT_DIR:-data/development/benchmark-runs/$(date +%Y%m%d-%H%M%S)}"
RUNS="${RUNS:-3}"
CACHE_WAIT_SECONDS="${CACHE_WAIT_SECONDS:-310}"
INCLUDE_EXPERIMENTAL="${INCLUDE_EXPERIMENTAL:-0}"

USER_MANAGEMENT_BASE_URL="${USER_MANAGEMENT_BASE_URL:-http://localhost:7500}"
JAEGER_BASE_URL="${JAEGER_BASE_URL:-http://localhost:11160}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing fixture manifest: $MANIFEST" >&2
  echo "Run the demo seeder first, then rerun this script." >&2
  exit 1
fi

mkdir -p "$OUT_DIR/graphql"
RESULTS="$OUT_DIR/timings.csv"
URLS="$OUT_DIR/urls.md"

json_get() {
  local fixture="$1"
  local path="$2"
  ruby -rjson -e '
    manifest = JSON.parse(File.read(ARGV[0]))
    fixture = manifest.fetch("fixtures").find { |item| item.fetch("name") == ARGV[1] }
    raise "unknown fixture #{ARGV[1]}" unless fixture
    value = ARGV[2].split(".").reduce(fixture) { |memo, key| memo.fetch(key) }
    puts value
  ' "$MANIFEST" "$fixture" "$path"
}

json_get_or() {
  local fixture="$1"
  local preferred_path="$2"
  local fallback_path="$3"
  ruby -rjson -e '
    manifest = JSON.parse(File.read(ARGV[0]))
    fixture = manifest.fetch("fixtures").find { |item| item.fetch("name") == ARGV[1] }
    raise "unknown fixture #{ARGV[1]}" unless fixture

    def dig_path(hash, path)
      path.split(".").reduce(hash) { |memo, key| memo.fetch(key) }
    end

    value = begin
      dig_path(fixture, ARGV[2])
    rescue KeyError
      dig_path(fixture, ARGV[3])
    end
    puts value
  ' "$MANIFEST" "$fixture" "$preferred_path" "$fallback_path"
}

curl_time() {
  local phase="$1"
  local label="$2"
  local method="$3"
  local url="$4"
  local body_file="${5:-}"
  local header="${6:-}"
  local output_file
  output_file="$OUT_DIR/${phase}-${label//[^A-Za-z0-9_.-]/_}.json"

  local curl_args=(-sS -o "$output_file" -w "%{http_code},%{time_total},%{size_download}")
  if [[ -n "$header" ]]; then
    curl_args+=(-H "$header")
  fi
  if [[ "$method" == "POST" ]]; then
    curl_args+=(-X POST -H "Content-Type: application/json" --data-binary "@$body_file")
  fi

  local result
  local curl_exit=0
  result="$(curl "${curl_args[@]}" "$url" 2>"$output_file.curl_error")" || curl_exit=$?
  if [[ "$curl_exit" -ne 0 ]]; then
    result="000,0,0"
    echo "curl failed for $phase,$label with exit $curl_exit; see $output_file.curl_error" >&2
  fi
  echo "$phase,$label,$method,$url,$result,$output_file" | tee -a "$RESULTS"
}

write_graphql_body() {
  local name="$1"
  local query_file="$2"
  local body_file="$OUT_DIR/graphql/$name.json"
  ruby -rjson -e 'puts JSON.generate({ query: File.read(ARGV[0]) })' "$query_file" > "$body_file"
  echo "$body_file"
}

deep_leaf="$(json_get deep_chain targets.leaf_account_id)"
deep_admin="$(json_get_or deep_chain targets.top_level_admin_user_id targets.admin_user_id)"
wide_root="$(json_get wide_org targets.root_account_id)"
wide_org="$(json_get wide_org organization_id)"
wide_admin="$(json_get_or wide_org targets.top_level_admin_user_id targets.admin_user_id)"
dense_account="$(json_get dense_account targets.account_id)"
dense_admin="$(json_get_or dense_account targets.top_level_admin_user_id targets.admin_user_id)"
branch_leaf="$(json_get branching_tree targets.leaf_account_id)"
branch_admin="$(json_get_or branching_tree targets.top_level_admin_user_id targets.admin_user_id)"
fanout_100k_org="$(json_get massive_fanout_100k organization_id)"
fanout_100k_admin="$(json_get_or massive_fanout_100k targets.top_level_admin_user_id targets.admin_user_id)"
fanout_50k_org="$(json_get massive_fanout_50k organization_id)"
fanout_50k_admin="$(json_get_or massive_fanout_50k targets.top_level_admin_user_id targets.admin_user_id)"
fanout_10k_org="$(json_get massive_fanout_10k organization_id)"
fanout_10k_admin="$(json_get_or massive_fanout_10k targets.top_level_admin_user_id targets.admin_user_id)"

deep_query="$OUT_DIR/graphql/deep_chain.graphql"
wide_query="$OUT_DIR/graphql/wide_org.graphql"
dense_query="$OUT_DIR/graphql/dense_account.graphql"
fanout_100k_query="$OUT_DIR/graphql/fanout_100k.graphql"
fanout_50k_query="$OUT_DIR/graphql/fanout_50k.graphql"
fanout_10k_query="$OUT_DIR/graphql/fanout_10k.graphql"

cat > "$deep_query" <<GRAPHQL
{
  accountWithParents(id: "$deep_leaf", as: "$deep_admin") {
    id
    name
    parentAccountId
    users {
      id
      email
      accountId
      groups {
        id
        name
      }
    }
  }
}
GRAPHQL

cat > "$wide_query" <<GRAPHQL
{
  organization(id: "$wide_org", as: "$wide_admin") {
    id
    name
    accounts {
      id
      name
      users {
        id
        email
        accountId
        groups {
          id
          name
        }
      }
    }
  }
}
GRAPHQL

cat > "$dense_query" <<GRAPHQL
{
  account(id: "$dense_account", as: "$dense_admin") {
    id
    name
    users {
      id
      email
      accountId
      groups {
        id
        name
      }
    }
  }
}
GRAPHQL

for size in 100k 50k 10k; do
  org_var="fanout_${size}_org"
  admin_var="fanout_${size}_admin"
  file_var="fanout_${size}_query"
  cat > "${!file_var}" <<GRAPHQL
{
  organization(id: "${!org_var}", as: "${!admin_var}") {
    id
    name
    accounts {
      id
      users {
        id
        email
        accountId
        groups {
          id
          name
        }
      }
    }
  }
}
GRAPHQL
done

deep_body="$(write_graphql_body deep_chain "$deep_query")"
wide_body="$(write_graphql_body wide_org "$wide_query")"
dense_body="$(write_graphql_body dense_account "$dense_query")"
fanout_100k_body="$(write_graphql_body fanout_100k "$fanout_100k_query")"
fanout_50k_body="$(write_graphql_body fanout_50k "$fanout_50k_query")"
fanout_10k_body="$(write_graphql_body fanout_10k "$fanout_10k_query")"

deep_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/deep-chain"
wide_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/wide-org"
dense_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/dense-account"
fanout_100k_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/massive-fanout-100k"
fanout_50k_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/massive-fanout-50k"
fanout_10k_demo="$USER_MANAGEMENT_BASE_URL/demo_queries/massive-fanout-10k"

cat > "$URLS" <<URLS
# Benchmark URLs

## User-Management Pages

- App root: $USER_MANAGEMENT_BASE_URL/
- Deep chain account page, experimental expansion probe: $USER_MANAGEMENT_BASE_URL/accounts/$deep_leaf?as=$deep_admin
- Branching tree account page, experimental expansion probe: $USER_MANAGEMENT_BASE_URL/accounts/$branch_leaf?as=$branch_admin
- Dense account page, experimental expansion probe: $USER_MANAGEMENT_BASE_URL/accounts/$dense_account?as=$dense_admin

## Demo Query Pages

- Deep chain accountWithParents: $deep_demo
- Wide organization accounts: $wide_demo
- Dense account users and groups: $dense_demo
- Massive fanout 100k users and groups: $fanout_100k_demo
- Massive fanout 50k users and groups: $fanout_50k_demo
- Massive fanout 10k users and groups: $fanout_10k_demo
- GraphiQL editor: $USER_MANAGEMENT_BASE_URL/graphiql

## Jaeger

- Jaeger home: $JAEGER_BASE_URL/
- user-management-service traces: $JAEGER_BASE_URL/search?service=user-management-service
- account-service traces: $JAEGER_BASE_URL/search?service=account-service
- organization-service traces: $JAEGER_BASE_URL/search?service=organization-service
- authorization-service traces: $JAEGER_BASE_URL/search?service=authorization-service
- user-service traces: $JAEGER_BASE_URL/search?service=user-service
- group-service traces: $JAEGER_BASE_URL/search?service=group-service

## Generated Files

- Timing CSV: $RESULTS
- Response bodies: $OUT_DIR
URLS

echo "phase,label,method,url,http_code,time_total,size_download,response_file" > "$RESULTS"

run_phase() {
  local phase="$1"
  echo
  echo "=== $phase ==="

  for run in $(seq 1 "$RUNS"); do
    curl_time "$phase" "web_root_$run" GET "$USER_MANAGEMENT_BASE_URL/"
    curl_time "$phase" "graphql_deep_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$deep_body"
    curl_time "$phase" "graphql_wide_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$wide_body"
    curl_time "$phase" "graphql_dense_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$dense_body"
    curl_time "$phase" "graphql_100k_expand_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$fanout_100k_body"
    curl_time "$phase" "graphql_50k_expand_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$fanout_50k_body"
    curl_time "$phase" "graphql_10k_expand_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$fanout_10k_body"

    if [[ "$INCLUDE_EXPERIMENTAL" == "1" ]]; then
      curl_time "$phase" "web_deep_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$deep_leaf?as=$deep_admin"
      curl_time "$phase" "web_branching_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$branch_leaf?as=$branch_admin"
      curl_time "$phase" "web_dense_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$dense_account?as=$dense_admin"
    fi
  done
}

echo "Writing benchmark output to $OUT_DIR"
echo "URLs: $URLS"
echo "Timings: $RESULTS"

run_phase "cold"
run_phase "warm"

echo
echo "Waiting ${CACHE_WAIT_SECONDS}s for the 5 minute cache TTL to expire..."
sleep "$CACHE_WAIT_SECONDS"

run_phase "after_cache_expiry"

echo
echo "Benchmark complete."
echo "Timing CSV: $RESULTS"
echo "URL list: $URLS"
echo "Jaeger: $JAEGER_BASE_URL/search?service=user-management-service"
