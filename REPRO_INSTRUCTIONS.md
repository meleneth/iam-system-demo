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
bash vacuum_analyze_dev_databases.sh
```

## Benchmark And Timing Commands

Run the full benchmark script. It executes cold, immediate warm, then post-cache-expiry phases. The wait defaults to 310 seconds so the 5 minute caches expire before the final phase.

```bash
bash benchmark_demo.sh
```

Useful overrides:

```bash
RUNS=1 CACHE_WAIT_SECONDS=10 bash benchmark_demo.sh
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
