#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${MANIFEST:-data/development/demo-fixtures/latest/fixture_manifest.json}"
OUT_DIR="${OUT_DIR:-data/development/benchmark-runs/$(date +%Y%m%d-%H%M%S)}"
RUNS="${RUNS:-3}"
CACHE_WAIT_SECONDS="${CACHE_WAIT_SECONDS:-310}"
INCLUDE_EXPERIMENTAL="${INCLUDE_EXPERIMENTAL:-0}"
INCLUDE_MSP_100K="${INCLUDE_MSP_100K:-1}"
INCLUDE_MSP_50K="${INCLUDE_MSP_50K:-1}"
INCLUDE_MSP_10K="${INCLUDE_MSP_10K:-1}"
COLD_ONLY="${COLD_ONLY:-0}"
REDIS_CACHE_SERVICES="${REDIS_CACHE_SERVICES:-accountcache authcache groupcache orgcache}"
MSP_READY_ATTEMPTS="${MSP_READY_ATTEMPTS:-120}"
MSP_READY_SLEEP_SECONDS="${MSP_READY_SLEEP_SECONDS:-1}"

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

configured_redis_toggle() {
  if [[ -n "${GLOBAL_IAM_DEMO_USE_REDIS:-}" ]]; then
    echo "$GLOBAL_IAM_DEMO_USE_REDIS"
    return
  fi

  if [[ -f development.env ]]; then
    awk -F= '$1 == "GLOBAL_IAM_DEMO_USE_REDIS" { print $2; found = 1 } END { if (!found) print "true" }' development.env
  else
    echo "true"
  fi
}

redis_enabled() {
  [[ "$(configured_redis_toggle)" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn])$ ]]
}

flush_redis_caches() {
  if ! redis_enabled; then
    echo "Redis cache toggle is disabled; skipping Redis FLUSHDB."
    return
  fi

  echo "Flushing Redis cache DBs through ./dc_dev..."
  for service in $REDIS_CACHE_SERVICES; do
    ./dc_dev exec -T "$service" redis-cli FLUSHDB >/dev/null
    echo "  flushed $service"
  done
}

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
    printf '{}\n' > "$output_file"
    echo "curl failed for $phase,$label with exit $curl_exit; see $output_file.curl_error" >&2
  fi
  echo "$phase,$label,$method,$url,$result,$output_file," | tee -a "$RESULTS"
}

write_graphql_body() {
  local name="$1"
  local query_file="$2"
  local body_file="$OUT_DIR/graphql/$name.json"
  ruby -rjson -e 'puts JSON.generate({ query: File.read(ARGV[0]) })' "$query_file" > "$body_file"
  echo "$body_file"
}

write_msp_fanout_body() {
  local name="$1"
  local msp_account_id="$2"
  local admin_user_id="$3"
  local continuance="${4:-}"
  local body_file="$OUT_DIR/graphql/${name}.json"

  ruby -rjson -e '
    name, msp_account_id, admin_user_id, continuance = ARGV
    args = {
      "mspAccountId" => msp_account_id,
      "as" => admin_user_id
    }
    args["continuance"] = continuance unless continuance.nil? || continuance.empty?
    argument_source = args.map { |key, value| "#{key}: #{value.to_json}" }.join(", ")
    query = <<~GRAPHQL
      {
        mspUserManagement(#{argument_source}) {
          loading
          loadedCount
          totalCount
          continuance
          message
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
    puts JSON.generate({ query: query })
  ' "$name" "$msp_account_id" "$admin_user_id" "$continuance" > "$body_file"

  echo "$body_file"
}

graphql_value() {
  local response_file="$1"
  local key="$2"

  ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV[0]))
    value = payload.dig("data", "mspUserManagement", ARGV[1])
    print value.nil? ? "" : value
  ' "$response_file" "$key"
}

graphql_has_errors() {
  local response_file="$1"

  ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV[0]))
    exit(payload["errors"].nil? || payload["errors"].empty? ? 1 : 0)
  ' "$response_file"
}

graphql_has_loading_error() {
  local response_file="$1"

  ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV[0]))
    messages = Array(payload["errors"]).map { |error| error["message"].to_s }
    exit(messages.any? { |message| message.downcase.include?("loading") } ? 0 : 1)
  ' "$response_file"
}

graphql_accounts_count() {
  local response_file="$1"

  ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV[0]))
    accounts = payload.dig("data", "mspUserManagement", "accounts") || []
    print accounts.length
  ' "$response_file"
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
fanout_100k_msp_account="$(json_get massive_fanout_100k targets.msp_account_id)"
fanout_100k_admin="$(json_get_or massive_fanout_100k targets.top_level_admin_user_id targets.admin_user_id)"
fanout_50k_msp_account="$(json_get massive_fanout_50k targets.msp_account_id)"
fanout_50k_admin="$(json_get_or massive_fanout_50k targets.top_level_admin_user_id targets.admin_user_id)"
fanout_10k_msp_account="$(json_get massive_fanout_10k targets.msp_account_id)"
fanout_10k_admin="$(json_get_or massive_fanout_10k targets.top_level_admin_user_id targets.admin_user_id)"

deep_query="$OUT_DIR/graphql/deep_chain.graphql"
wide_query="$OUT_DIR/graphql/wide_org.graphql"
dense_query="$OUT_DIR/graphql/dense_account.graphql"
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

deep_body="$(write_graphql_body deep_chain "$deep_query")"
wide_body="$(write_graphql_body wide_org "$wide_query")"
dense_body="$(write_graphql_body dense_account "$dense_query")"

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

echo "phase,label,method,url,http_code,time_total,size_download,response_file,notes" > "$RESULTS"

run_msp_fanout_walk() {
  local phase="$1"
  local label="$2"
  local msp_account_id="$3"
  local admin_user_id="$4"
  local run="$5"

  local continuance=""
  local page=1
  local total_time="0"
  local total_download="0"
  local total_accounts="0"
  local last_http_code="200"
  local final_response=""
  local stop_reason=""
  local loading_probes=0
  local completed_pages=0
  local request=1

  while :; do
    local body_file
    body_file="$(write_msp_fanout_body "${label}_${run}_page_${page}_request_${request}" "$msp_account_id" "$admin_user_id" "$continuance")"
    local request_label="${label}_page_${page}_request_${request}_${run}"
    curl_time "$phase" "$request_label" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$body_file"

    final_response="$OUT_DIR/${phase}-${request_label}.json"
    local row
    row="$(tail -n 1 "$RESULTS")"
    IFS=, read -r _ _ _ _ last_http_code page_time page_download _ _ <<< "$row"

    total_time="$(ruby -e 'puts ARGV.map(&:to_f).sum' "$total_time" "$page_time")"
    total_download=$((total_download + page_download))

    if [[ "$last_http_code" == "000" ]]; then
      stop_reason="curl_failed"
      echo "Stopping $phase/$label run $run: curl failed on page $page." >&2
      break
    fi

    total_accounts=$((total_accounts + $(graphql_accounts_count "$final_response")))

    if graphql_has_errors "$final_response"; then
      if graphql_has_loading_error "$final_response"; then
        loading_probes=$((loading_probes + 1))
        if [[ "$loading_probes" -ge "$MSP_READY_ATTEMPTS" ]]; then
          stop_reason="loading_timeout"
          echo "Stopping $phase/$label run $run: authorization cache still loading after $loading_probes probes." >&2
          break
        fi

        echo "Waiting for $phase/$label run $run authorization cache readiness probe $loading_probes/$MSP_READY_ATTEMPTS..." >&2
        request=$((request + 1))
        sleep "$MSP_READY_SLEEP_SECONDS"
        continue
      fi

      stop_reason="graphql_errors"
      echo "Stopping $phase/$label run $run: GraphQL returned errors on page $page." >&2
      break
    fi

    local loading
    loading="$(graphql_value "$final_response" loading)"
    if [[ "$loading" == "true" ]]; then
      loading_probes=$((loading_probes + 1))
      if [[ "$loading_probes" -ge "$MSP_READY_ATTEMPTS" ]]; then
        stop_reason="loading_timeout"
        echo "Stopping $phase/$label run $run: authorization cache still loading after $loading_probes probes." >&2
        break
      fi

      echo "Waiting for $phase/$label run $run authorization cache readiness probe $loading_probes/$MSP_READY_ATTEMPTS..." >&2
      request=$((request + 1))
      sleep "$MSP_READY_SLEEP_SECONDS"
      continue
    fi

    continuance="$(graphql_value "$final_response" continuance)"
    completed_pages=$page
    [[ -n "$continuance" ]] || break
    page=$((page + 1))
    request=1
  done

  local notes="pages=$completed_pages accounts=$total_accounts loading_probes=$loading_probes"
  if [[ -n "$stop_reason" ]]; then
    notes="$notes stop=$stop_reason"
  fi

  echo "$phase,${label}_full_walk_$run,POST,$USER_MANAGEMENT_BASE_URL/graphql,$last_http_code,$total_time,$total_download,$final_response,$notes" | tee -a "$RESULTS"
}

run_phase() {
  local phase="$1"
  echo
  echo "=== $phase ==="

  for run in $(seq 1 "$RUNS"); do
    curl_time "$phase" "web_root_$run" GET "$USER_MANAGEMENT_BASE_URL/"
    curl_time "$phase" "graphql_deep_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$deep_body"
    curl_time "$phase" "graphql_wide_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$wide_body"
    curl_time "$phase" "graphql_dense_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$dense_body"
    if [[ "$INCLUDE_MSP_100K" == "1" ]]; then
      run_msp_fanout_walk "$phase" "graphql_100k_fanout" "$fanout_100k_msp_account" "$fanout_100k_admin" "$run"
    fi
    if [[ "$INCLUDE_MSP_50K" == "1" ]]; then
      run_msp_fanout_walk "$phase" "graphql_50k_fanout" "$fanout_50k_msp_account" "$fanout_50k_admin" "$run"
    fi
    if [[ "$INCLUDE_MSP_10K" == "1" ]]; then
      run_msp_fanout_walk "$phase" "graphql_10k_fanout" "$fanout_10k_msp_account" "$fanout_10k_admin" "$run"
    fi

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

run_phase "startup_cold"

if [[ "$COLD_ONLY" == "1" ]]; then
  echo
  echo "Skipping warm and cache-expiry phases because COLD_ONLY=1."
  echo
  echo "Benchmark complete."
  echo "Timing CSV: $RESULTS"
  echo "URL list: $URLS"
  echo "Jaeger: $JAEGER_BASE_URL/search?service=user-management-service"
  exit 0
fi

echo
echo "Repeating cold-cache run after startup noise is out of the way."
flush_redis_caches
run_phase "cold_after_redis_flush"

run_phase "warm"

if [[ "$CACHE_WAIT_SECONDS" -gt 0 ]]; then
  echo
  echo "Waiting ${CACHE_WAIT_SECONDS}s for the 5 minute cache TTL to expire..."
  sleep "$CACHE_WAIT_SECONDS"

  run_phase "after_cache_expiry"
else
  echo
  echo "Skipping cache-expiry phase because CACHE_WAIT_SECONDS=0."
fi

echo
echo "Benchmark complete."
echo "Timing CSV: $RESULTS"
echo "URL list: $URLS"
echo "Jaeger: $JAEGER_BASE_URL/search?service=user-management-service"
