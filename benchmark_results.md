# Redis Toggle Benchmark Results

Date: 2026-06-29

Configuration:

- Redis enabled run: `GLOBAL_IAM_DEMO_USE_REDIS=true`
- Redis disabled run: `GLOBAL_IAM_DEMO_USE_REDIS=false`
- Wrapper used for development stack operations: `./dc_dev`
- Benchmark command shape: `RUNS=1 CACHE_WAIT_SECONDS=0 ./benchmark_demo.sh`
- Redis-enabled CSV: `data/development/benchmark-runs/redis-on-valid-20260629-041001/timings.csv`
- Redis-disabled CSV: `data/development/benchmark-runs/redis-off-valid-20260629-041143/timings.csv`

Runtime verification:

- Redis enabled:
  - `account-service`: `true Redis true`
  - `authorization-service`: `true Redis true`
  - `organization-service`: `true Redis true`
- Redis disabled:
  - `account-service`: `false IamDemo::NullRedisCache false`
  - `authorization-service`: `false IamDemo::NullRedisCache false`
  - `organization-service`: `false IamDemo::NullRedisCache false`

All benchmarked GraphQL requests below returned HTTP 200.

## GraphQL Timings

Times are `curl` `time_total` values in seconds. Lower is better.

| Phase | Query | Redis on | Redis off | Delta off-on |
| --- | ---: | ---: | ---: | ---: |
| cold | deep chain | 0.418 | 2.237 | +1.819 |
| cold | wide org | 7.080 | 4.590 | -2.491 |
| cold | dense account | 15.242 | 11.981 | -3.261 |
| cold | 100k fanout | 0.225 | 0.267 | +0.042 |
| cold | 50k fanout | 0.200 | 0.207 | +0.007 |
| cold | 10k fanout | 0.173 | 0.198 | +0.025 |
| warm | deep chain | 0.297 | 0.496 | +0.198 |
| warm | wide org | 2.115 | 3.849 | +1.734 |
| warm | dense account | 10.575 | 11.491 | +0.917 |
| warm | 100k fanout | 0.180 | 0.257 | +0.077 |
| warm | 50k fanout | 0.164 | 0.226 | +0.063 |
| warm | 10k fanout | 0.201 | 0.210 | +0.009 |
| after cache expiry* | deep chain | 0.357 | 0.500 | +0.143 |
| after cache expiry* | wide org | 2.628 | 3.800 | +1.172 |
| after cache expiry* | dense account | 10.184 | 11.459 | +1.275 |
| after cache expiry* | 100k fanout | 0.166 | 0.211 | +0.044 |
| after cache expiry* | 50k fanout | 0.159 | 0.217 | +0.058 |
| after cache expiry* | 10k fanout | 0.150 | 0.208 | +0.057 |

`*` `CACHE_WAIT_SECONDS=0`, so this phase is another immediate warm-ish pass rather than a real TTL-expired pass.

## Notes

- The Redis-on warm pass shows the intended cache benefit on the wide org and dense account queries.
- The cold pass is noisier because each run includes fresh process/database/cache state and the first request can pay startup or connection costs.
- The initial Redis-on benchmark attempt hit HTTP 500 because `group-service` had stopped after a stale Rails PID check. That was fixed by removing `tmp/pids/server.pid` in the group service entrypoint before Rails server startup; the table above only uses the later valid HTTP 200 runs.
