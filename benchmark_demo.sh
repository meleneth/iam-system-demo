#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${MANIFEST:-data/development/demo-fixtures/latest/fixture_manifest.json}"
OUT_DIR="${OUT_DIR:-data/development/benchmark-runs/$(date +%Y%m%d-%H%M%S)}"
RUNS="${RUNS:-3}"
CACHE_WAIT_SECONDS="${CACHE_WAIT_SECONDS:-0}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-600}"
RUN_FAILED=0
ARCHIVE_TRACES="${ARCHIVE_TRACES:-1}"
INCLUDE_EXPERIMENTAL="${INCLUDE_EXPERIMENTAL:-0}"
INCLUDE_MSP_100K="${INCLUDE_MSP_100K:-1}"
INCLUDE_MSP_50K="${INCLUDE_MSP_50K:-1}"
INCLUDE_MSP_10K="${INCLUDE_MSP_10K:-1}"
COLD_ONLY="${COLD_ONLY:-0}"
FOCUSED_ORGANIZATION_ONLY="${FOCUSED_ORGANIZATION_ONLY:-0}"
REDIS_CACHE_SERVICES="${REDIS_CACHE_SERVICES:-accountcache authcache groupcache orgcache}"
MSP_READY_ATTEMPTS="${MSP_READY_ATTEMPTS:-120}"
MSP_READY_SLEEP_SECONDS="${MSP_READY_SLEEP_SECONDS:-1}"
GRAFANA_BASE_URL="${GRAFANA_BASE_URL:-http://localhost:11150}"
GRAFANA_DASHBOARD_UID="${GRAFANA_DASHBOARD_UID:-iam-demo-cache-hit-miss}"
GRAFANA_ANNOTATION_USER="${GRAFANA_ANNOTATION_USER:-admin}"
GRAFANA_ANNOTATION_PASSWORD="${GRAFANA_ANNOTATION_PASSWORD:-admin}"
GRAFANA_ANNOTATIONS_ENABLED="${GRAFANA_ANNOTATIONS_ENABLED:-1}"

USER_MANAGEMENT_BASE_URL="${USER_MANAGEMENT_BASE_URL:-http://localhost:7500}"
JAEGER_BASE_URL="${JAEGER_BASE_URL:-http://localhost:11160}"

configured_env_value() {
  local name="$1"
  local fallback="$2"
  local current_value="${!name:-}"
  if [[ -n "$current_value" ]]; then
    echo "$current_value"
    return
  fi

  if [[ -f development.env ]]; then
    awk -F= -v name="$name" -v fallback="$fallback" '$1 == name { print $2; found = 1 } END { if (!found) print fallback }' development.env
  else
    echo "$fallback"
  fi
}

RETRIEVAL_MODE="$(configured_env_value IAM_DEMO_RETRIEVAL_MODE batched)"
AUTHORIZATION_MODE="$(configured_env_value AUTHORIZATION_CHECK_MODE can)"
BATCH_SIZE="$(configured_env_value IAM_DEMO_BATCH_SIZE 1000)"
REVISION="$(git rev-parse HEAD 2>/dev/null || true)"

if [[ ! "$RETRIEVAL_MODE" =~ ^(serial|batched)$ ]]; then
  echo "IAM_DEMO_RETRIEVAL_MODE must be serial or batched, got: $RETRIEVAL_MODE" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing fixture manifest: $MANIFEST" >&2
  echo "Run the demo seeder first, then rerun this script." >&2
  exit 1
fi

mkdir -p "$OUT_DIR/graphql" "$OUT_DIR/traces"
TRACE_PENDING="$OUT_DIR/traces/pending.tsv"
: > "$TRACE_PENDING"
RESULTS="$OUT_DIR/timings.csv"
URLS="$OUT_DIR/urls.md"
METADATA="$OUT_DIR/metadata.json"

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

grafana_annotate() {
  local text="$1"
  local tags="${2:-benchmark}"

  [[ "$GRAFANA_ANNOTATIONS_ENABLED" == "1" ]] || return 0

  local response_file="$OUT_DIR/grafana_annotation_${text//[^A-Za-z0-9_.-]/_}.json"
  ruby -rjson -e '
    text, dashboard_uid, raw_tags = ARGV
    tags = raw_tags.split(",").map(&:strip).reject(&:empty?)
    puts JSON.generate({
      dashboardUID: dashboard_uid,
      tags: tags,
      text: text
    })
  ' "$text" "$GRAFANA_DASHBOARD_UID" "$tags" |
    curl -sS \
      -u "$GRAFANA_ANNOTATION_USER:$GRAFANA_ANNOTATION_PASSWORD" \
      -H "Content-Type: application/json" \
      -X POST \
      --data-binary @- \
      "$GRAFANA_BASE_URL/api/annotations" \
      > "$response_file" 2>"$response_file.curl_error" ||
    echo "Grafana annotation failed for '$text'; see $response_file.curl_error" >&2
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

  local trace_id parent_id
  read -r trace_id parent_id <<< "$(ruby -rsecurerandom -e 'puts "#{SecureRandom.hex(16)} #{SecureRandom.hex(8)}"')"
  local trace_file="$OUT_DIR/traces/${phase}-${label//[^A-Za-z0-9_.-]/_}.json"
  local curl_args=(-H "traceparent: 00-$trace_id-$parent_id-01" -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -D "$output_file.headers" -o "$output_file" -w "%{http_code},%{time_total},%{size_download}")
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
    echo "curl failed for $phase,$label with exit $curl_exit; see $output_file.curl_error" >&2
  fi
  local http_code="${result%%,*}"
  local kind="html"
  [[ "$url" == *"/graphql" ]] && kind="graphql"
  [[ "$url" == *"/organization_user_management/partition?"* ]] && kind="partition"
  local notes
  notes="$(ruby scripts/benchmark_response.rb "$output_file" "$http_code" "$curl_exit" "$kind" "$trace_id" "$trace_file")"
  [[ "$notes" == outcome=ok* ]] || RUN_FAILED=1
  printf '%s\t%s\t%s\n' "$trace_id" "$parent_id" "$trace_file" >> "$TRACE_PENDING"
  notes="$notes trace_id=$trace_id"
  echo "$phase,$RETRIEVAL_MODE,$label,$method,$url,$result,$output_file,$notes" | tee -a "$RESULTS"
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
organization_fixture="${ORGANIZATION_FIXTURE:-wide_org}"
wide_root="$(json_get wide_org targets.root_account_id)"
wide_org="$(json_get "$organization_fixture" organization_id)"
wide_admin="$(json_get_or "$organization_fixture" targets.top_level_admin_user_id targets.admin_user_id)"
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
organization_partition_url="$USER_MANAGEMENT_BASE_URL/organization_user_management/partition?organization_id=$wide_org&as=$wide_admin&frame_id=benchmark-partition-root"

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
- Full-organization User Management partition: $organization_partition_url
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
- Run metadata: $METADATA
- Jaeger trace JSON and export status: $OUT_DIR/traces
URLS

echo "phase,retrieval_mode,label,method,url,http_code,time_total,size_download,response_file,notes" > "$RESULTS"

ruby -rjson -e '
  puts JSON.pretty_generate({
    retrieval_mode: ARGV[0],
    authorization_mode: ARGV[1],
    redis_enabled: ARGV[2],
    batch_size: ARGV[3].to_i,
    manifest: ARGV[4],
    focused_organization_only: ARGV[5] == "1",
    revision: ARGV[9].empty? ? nil : ARGV[9],
    archive_traces: ARGV[8] == "1",
    request_timeout_seconds: ARGV[6].to_f,
    cache_wait_seconds: ARGV[7].to_i,
    cold_policy: "flush before each complete workload",
    warm_policy: "prime each complete workload immediately before measurement"
  })
' "$RETRIEVAL_MODE" "$AUTHORIZATION_MODE" "$(configured_redis_toggle)" "$BATCH_SIZE" "$MANIFEST" "$FOCUSED_ORGANIZATION_ONLY" "$REQUEST_TIMEOUT_SECONDS" "$CACHE_WAIT_SECONDS" "$ARCHIVE_TRACES" "$REVISION" > "$METADATA"

run_msp_fanout_walk() {
  local phase="$1"
  local label="$2"
  local msp_account_id="$3"
  local admin_user_id="$4"
  local run="$5"

  grafana_annotate "$phase $label run $run started" "benchmark,fanout,$phase,$label"

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
    IFS=, read -r _ _ _ _ _ last_http_code page_time page_download _ _ <<< "$row"

    total_time="$(ruby -e 'puts ARGV.map(&:to_f).sum' "$total_time" "$page_time")"
    total_download=$((total_download + page_download))

    if [[ "$last_http_code" != "200" ]]; then
      stop_reason="curl_failed"
      echo "Stopping $phase/$label run $run: curl failed on page $page." >&2
      break
    fi

    if [[ "$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("outcome")' "$final_response.result.json")" == "invalid_response" ]]; then
      stop_reason="invalid_response"
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
    RUN_FAILED=1
    notes="$notes stop=$stop_reason"
  fi

  echo "$phase,$RETRIEVAL_MODE,${label}_full_walk_$run,POST,$USER_MANAGEMENT_BASE_URL/graphql,$last_http_code,$total_time,$total_download,$final_response,$notes" | tee -a "$RESULTS"
  grafana_annotate "$phase $label run $run finished: $notes" "benchmark,fanout,$phase,$label"
}

# Flush/prime once for each complete workload, never between its continuation pages.
run_sample() {
  local phase="$1"
  local command="$2"
  shift 2
  case "$phase" in
    cold_after_redis_flush) flush_redis_caches ;;
    warm) "$command" "warm_prime" "$@" ;;
    after_cache_expiry)
      "$command" "expiry_prime" "$@"
      sleep "$CACHE_WAIT_SECONDS"
      ;;
  esac
  "$command" "$phase" "$@"
  # Export after the complete sample, so collector polling does not delay pages
  # or separate a warm measurement from its priming request.
  if [[ "$ARCHIVE_TRACES" == "1" ]]; then
    local trace_id parent_id trace_file
    while IFS=$'\t' read -r trace_id parent_id trace_file; do
      ruby scripts/archive_trace.rb "$JAEGER_BASE_URL" "$trace_id" "$parent_id" "$trace_file" || RUN_FAILED=1
    done < "$TRACE_PENDING"
  fi
  : > "$TRACE_PENDING"
}

run_organization_walk() {
  local phase="$1" label="$2" url="$organization_partition_url"
  local page=1 total_accounts=0 expected_accounts="" total_time=0 total_download=0
  local response_file summary next_path outcome row http_code page_time page_download
  local seen_paths="|$url|"
  while :; do
    curl_time "$phase" "${label}_page_$page" GET "$url"
    response_file="$OUT_DIR/${phase}-${label}_page_$page.json"
    summary="$response_file.result.json"
    row="$(tail -n 1 "$RESULTS")"
    IFS=, read -r _ _ _ _ _ http_code page_time page_download _ _ <<< "$row"
    total_time="$(ruby -e 'puts ARGV.map(&:to_f).sum' "$total_time" "$page_time")"
    total_download=$((total_download + page_download))
    outcome="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("outcome")' "$summary")"
    [[ "$outcome" == "ok" ]] || break
    local counts
    counts="$(ruby -rjson -e 'j=JSON.parse(File.read(ARGV[0])); puts [j.fetch("accounts"),j.fetch("total_accounts")].join(" ")' "$summary")"
    local returned expected
    read -r returned expected <<< "$counts"
    if [[ -n "$expected_accounts" && "$expected_accounts" != "$expected" ]]; then
      outcome="changing_account_total"; RUN_FAILED=1; break
    fi
    expected_accounts="$expected"
    total_accounts=$((total_accounts + returned))
    next_path="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["next_path"]' "$summary")"
    [[ -n "$next_path" ]] || break
    if [[ "$next_path" != /organization_user_management/partition\?* || "$seen_paths" == *"|$next_path|"* || "$returned" == "0" ]]; then
      outcome="invalid_continuation"; RUN_FAILED=1; break
    fi
    seen_paths+="$next_path|"
    url="$USER_MANAGEMENT_BASE_URL$next_path"
    page=$((page + 1))
  done
  if [[ "$outcome" == "ok" && "$total_accounts" != "$expected_accounts" ]]; then
    outcome="incomplete_walk"; RUN_FAILED=1
  fi
  echo "$phase,$RETRIEVAL_MODE,${label}_full_walk,GET,$organization_partition_url,$http_code,$total_time,$total_download,$response_file,outcome=$outcome pages=$page accounts=$total_accounts" | tee -a "$RESULTS"
}

run_phase() {
  local phase="$1"
  echo
  echo "=== $phase ==="
  grafana_annotate "$phase started" "benchmark,phase,$phase"

  for run in $(seq 1 "$RUNS"); do
    grafana_annotate "$phase run $run started" "benchmark,run,$phase"
    run_sample "$phase" run_organization_walk "organization_user_management_partition_$run"
    if [[ "$FOCUSED_ORGANIZATION_ONLY" == "1" ]]; then
      grafana_annotate "$phase run $run finished" "benchmark,run,$phase,retrieval-$RETRIEVAL_MODE"
      continue
    fi
    run_sample "$phase" curl_time "web_root_$run" GET "$USER_MANAGEMENT_BASE_URL/"
    run_sample "$phase" curl_time "graphql_deep_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$deep_body"
    run_sample "$phase" curl_time "graphql_wide_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$wide_body"
    run_sample "$phase" curl_time "graphql_dense_$run" POST "$USER_MANAGEMENT_BASE_URL/graphql" "$dense_body"
    if [[ "$INCLUDE_MSP_100K" == "1" ]]; then
      run_sample "$phase" run_msp_fanout_walk "graphql_100k_fanout" "$fanout_100k_msp_account" "$fanout_100k_admin" "$run"
    fi
    if [[ "$INCLUDE_MSP_50K" == "1" ]]; then
      run_sample "$phase" run_msp_fanout_walk "graphql_50k_fanout" "$fanout_50k_msp_account" "$fanout_50k_admin" "$run"
    fi
    if [[ "$INCLUDE_MSP_10K" == "1" ]]; then
      run_sample "$phase" run_msp_fanout_walk "graphql_10k_fanout" "$fanout_10k_msp_account" "$fanout_10k_admin" "$run"
    fi

    if [[ "$INCLUDE_EXPERIMENTAL" == "1" ]]; then
      run_sample "$phase" curl_time "web_deep_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$deep_leaf?as=$deep_admin"
      run_sample "$phase" curl_time "web_branching_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$branch_leaf?as=$branch_admin"
      run_sample "$phase" curl_time "web_dense_account_$run" GET "$USER_MANAGEMENT_BASE_URL/accounts/$dense_account?as=$dense_admin"
    fi
    grafana_annotate "$phase run $run finished" "benchmark,run,$phase"
  done

  grafana_annotate "$phase finished" "benchmark,phase,$phase"
}

echo "Writing benchmark output to $OUT_DIR"
echo "URLs: $URLS"
echo "Timings: $RESULTS"
echo "Metadata: $METADATA"
grafana_annotate "benchmark started: $OUT_DIR" "benchmark,lifecycle"

run_phase "cold_after_redis_flush"

if [[ "$COLD_ONLY" == "1" ]]; then
  echo
  echo "Skipping warm and cache-expiry phases because COLD_ONLY=1."
  echo
  echo "Benchmark complete."
  echo "Timing CSV: $RESULTS"
  echo "URL list: $URLS"
  echo "Jaeger: $JAEGER_BASE_URL/search?service=user-management-service"
  grafana_annotate "benchmark complete: $OUT_DIR" "benchmark,lifecycle"
  exit "$RUN_FAILED"
fi

run_phase "warm"

if [[ "$CACHE_WAIT_SECONDS" -gt 0 ]]; then
  echo
  echo "Each expiry sample will be primed, then wait ${CACHE_WAIT_SECONDS}s."

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
grafana_annotate "benchmark complete: $OUT_DIR" "benchmark,lifecycle"

exit "$RUN_FAILED"
