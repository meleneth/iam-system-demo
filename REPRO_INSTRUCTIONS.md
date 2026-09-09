# Repro Instructions

These commands use the development stack through `./dc_dev`.

## Build And Start

From the repository root:

```bash
./dc_dev build
./dc_dev up -d
```

To drop and recreate all development databases before a run:

```bash
bash reset_dev_databases.sh
```

Prepare the Rails databases explicitly. The web containers also run `db:prepare` on boot, but these commands make the repro less sensitive to worker startup order:

```bash
./dc_dev run --rm user-service bin/rails db:prepare
./dc_dev run --rm account-service bin/rails db:prepare
./dc_dev run --rm authorization-service bin/rails db:prepare
./dc_dev run --rm organization-service bin/rails db:prepare
./dc_dev run --rm group-service bin/rails db:prepare
```

Restart everything after the database prepare step:

```bash
./dc_dev up -d
./dc_dev ps
```

## Populate Data

This seeds the named fixture accounts plus random filler, spreads the fixture events through the full job stream, and writes timing/demo files under `./data/development/demo-fixtures/latest`.

For the full timing dataset:

```bash
./dc_dev run --rm -e USER_COUNT=2000000 -e DEMO_PROGRESS_INTERVAL=10000 user-management-service bin/rails runner scripts/demo_user_seeder.rb
```

For a quick smoke test only, use:

```bash
./dc_dev run --rm -e USER_COUNT=1300 user-management-service bin/rails runner scripts/demo_user_seeder.rb
```

The seeder waits for the grants queue every 10,000 jobs and waits for the seed queues to drain before it exits. To watch worker progress:

```bash
./dc_dev logs -f user-create-service-worker account-create-service-worker organization-create-service-worker grants-create-service-worker groups-create-service-worker
```

After the workers finish, refresh PostgreSQL statistics before collecting timings:

```bash
./analyze_databases.sh
```

## Benchmark And Timing Commands

Run the full benchmark script. Each cold workload gets its own Redis flush; each warm workload gets a separate priming run. Post-cache-expiry sampling is opt-in with `CACHE_WAIT_SECONDS=310`. Trace JSON is archived by default.

```bash
bash benchmark_demo.sh
```

Useful overrides:

```bash
RUNS=1 CACHE_WAIT_SECONDS=0 bash benchmark_demo.sh
OUT_DIR=data/development/benchmark-runs/manual RUNS=5 bash benchmark_demo.sh
```

By default the benchmark uses the stable user-management surfaces: the app root and GraphQL queries that expand accounts, users, and groups. To also run the heavier account-page expansion probes, use:

```bash
INCLUDE_EXPERIMENTAL=1 RUNS=1 bash benchmark_demo.sh
```

The benchmark writes:

- `timings.csv`: phase, label, method, URL, HTTP status, total time, response size, response file.
- `urls.md`: app, GraphiQL, Jaeger, and generated benchmark links.
- response bodies under the same output directory.

The older generated one-shot timing scripts are still available:

```bash
bash data/development/demo-fixtures/latest/rest_curl_examples.sh
bash data/development/demo-fixtures/latest/graphql_curl_examples.sh
```

The generated fixture manifest and query links are here:

```bash
ls data/development/demo-fixtures/latest
```

## Demo Links

All links in this section use host-facing `dc_dev` ports from `development.env`, not the container-internal `:3000` ports.

After running `bash benchmark_demo.sh`, open the generated `urls.md` file under `data/development/benchmark-runs/...` for the expanded, fixture-specific list used by that run.

For user-management URLs, `as` is forwarded as the downstream `pad-user-id` header. For account or organization fixture links, use the fixture's `targets.top_level_admin_user_id`: find the ultimate parent account for the account being inspected, then use the admin user on that top-level account. Do not use a login name and do not use `IAM_SYSTEM` in browser-facing user-management links.

Main web app:

http://localhost:7500/

Experimental account page using the deep-chain leaf account:

http://localhost:7500/accounts/ed253374-9a50-51cd-ac06-d0d636dd42bd?as=f9684f2b-2fd0-5dd0-b783-9cb238dbc396

GraphiQL:

http://localhost:7500/graphiql

Deep-chain demo query:

http://localhost:7500/demo_queries/deep-chain

Wide-organization users and groups demo query:

http://localhost:7500/demo_queries/wide-org

Dense-account users and groups demo query:

http://localhost:7500/demo_queries/dense-account

Massive fanout 100k users and groups demo query:

http://localhost:7500/demo_queries/massive-fanout-100k

Massive fanout 50k users and groups demo query:

http://localhost:7500/demo_queries/massive-fanout-50k

Massive fanout 10k users and groups demo query:

http://localhost:7500/demo_queries/massive-fanout-10k

Jaeger:

http://localhost:11160/

Jaeger search for the user-management service:

http://localhost:11160/search?service=user-management-service

Host-facing service ports for ad hoc checks:

- user-management-service: http://localhost:7500
- user-service: http://localhost:11220
- account-service: http://localhost:11230
- authorization-service: http://localhost:11240
- organization-service: http://localhost:11250
- group-service: http://localhost:11115
- Jaeger: http://localhost:11160

## Useful Cleanup

Stop the stack:

```bash
./dc_dev down
```

Reset development data completely:

```bash
./dc_dev down
bash reset_dev_databases.sh
```

### Retrieval batch size

`IAM_DEMO_BATCH_SIZE` controls outbound retrieval chunks and organization/MSP
partition sizes. It defaults to `1000`; valid values are integers from `1` through
`10000`. Invalid values fail explicitly. Recreate affected services through
`./dc_dev up -d` after changing the setting. GraphQL Account, User, GroupUser,
Group, hierarchy, and count loads use this setting, including the front-door
lookups and legacy account probes. Serial retrieval still sends one key per call.
Large Account/hierarchy/count collections use JSON POST bodies to avoid URL size
limits. Account-source concurrency remains bounded at four workers.

### Isolated benchmark samples

`benchmark_demo.sh` flushes service Redis caches before **each** cold workload,
including every repetition. It does not flush between continuation pages. Each
warm workload gets an immediately preceding priming walk; `warm_prime` rows are
retained separately and must not be included in warm timing statistics. Process
startup is no longer labeled or measured as cache coldness.

The organization case follows all partition continuations and emits page rows
plus a `full_walk` row. `ORGANIZATION_FIXTURE=wide_org` selects its manifest fixture.
Response headers, bodies, and `.result.json` outcome/count summaries are saved.
GraphQL errors and incomplete organization walks fail the run even with HTTP 200.
`REQUEST_TIMEOUT_SECONDS` defaults to 600; timeout rows retain curl's elapsed time
and partial response and are marked `outcome=timeout`, not successful timings.
A run with failed samples exits nonzero while retaining the evidence.

TTL-expiry sampling is opt-in (`CACHE_WAIT_SECONDS=310`). Each expiry sample is
primed and then waits that duration; the default is `0` to skip this extra phase.
Redis-disabled runs skip flushes. Do not run unrelated traffic against the stack
while collecting isolated cache measurements.

Harness regression checks (fake services, no benchmark traffic):

```bash
./dc_test run --rm --no-deps -v "$PWD:/workspace" -w /workspace \
  user-management-service ruby test/benchmark_test.rb
```

### Archived trace evidence

Trace export is enabled by default. Every request sends a sampled W3C
`traceparent`, and its timing row and `.result.json` contain the trace ID.
After each complete workload (including its priming run), the harness fetches
Jaeger's `/api/traces/:id` response and saves it to `traces/<phase>-<sample>.json`.
Polling is outside measured requests and continuation walks.

A neighboring `.status.json` records the trace ID, span count, timestamp, and
export outcome. The exporter waits for spans to settle and checks that the
initiating request and referenced parents are present. Missing/incomplete exports
make the benchmark exit nonzero; any partial JSON is retained. Settling is a
practical check, not proof that the telemetry pipeline dropped no spans.
`TRACE_EXPORT_TIMEOUT_SECONDS=60` and `TRACE_QUIET_SECONDS=5` control polling.
`ARCHIVE_TRACES=0` explicitly skips exporting for exploratory timing-only runs.
Keep the complete output directory as the article evidence artifact.

```bash
./dc_test run --rm --no-deps -v "$PWD:/workspace" -w /workspace \
  user-management-service ruby test/archive_trace_test.rb
```

### Refresh database statistics after seeding

Queue count reaching zero remains the seed-readiness convention. Before running
benchmarks, update planner statistics with:

```bash
./analyze_databases.sh       # development stack, via ./dc_dev
./analyze_databases.sh test  # test stack, via ./dc_test
./analyze_databases.sh prod  # production stack, via ./dc_prod
```

The script discovers PostgreSQL services (`*-db` and `*-db-*`) from the selected
wrapper configuration and runs `ANALYZE` on every connectable non-template
database, including any queue/cache/cable databases in those containers. It stops
on database errors. Run it after inserts have drained and outside measured
requests; it updates statistics without deleting data or flushing Redis.

### Planned console collection and hierarchy comparisons

The complete multiuser/no-X collection procedure, paired case matrix, smoke gates,
and resume rules are in [BENCHMARK_PLAN.md](BENCHMARK_PLAN.md). Preview with
`./collect_article_evidence.sh --plan`; run it only after preparing the host for
measurement. `COLLECTION_DIR` selects the resumable evidence directory.

For a standalone hierarchy comparison against the currently configured stack:

```bash
GLOBAL_IAM_DEMO_USE_REDIS=false AUTHORIZATION_CHECK_MODE=can \
  IAM_DEMO_BATCH_SIZE=1000 EXPERIMENT=all RUNS=3 ./benchmark_hierarchies.sh
```

`EXPERIMENT=cte` compares repeated parent reads with a single hierarchy request;
`EXPERIMENT=batch` compares individual hierarchy requests with collection calls.
Both use real fixture actors and check returned parent chains. The batch endpoint
now authorizes real actors for the complete requested set before returning data;
its existing IAM_SYSTEM internal path remains intact. No actor is promoted to an
internal identity for the benchmark.

Service-owned Redis caches use logical database **1**. The benchmark flushes that
database explicitly; `REDIS_CACHE_DB` defaults to `1` for standalone drivers.
