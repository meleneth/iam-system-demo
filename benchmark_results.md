# Redis Toggle Benchmark Results

Date: 2026-06-29

Configuration:

- Redis enabled run: `GLOBAL_IAM_DEMO_USE_REDIS=true`
- Redis disabled run: `GLOBAL_IAM_DEMO_USE_REDIS=false`
- Wrapper used for development stack operations: `./dc_dev`
- Benchmark command shape: `RUNS=1 CACHE_WAIT_SECONDS=0 ./benchmark_demo.sh`
- Redis-enabled CSV: `data/development/benchmark-runs/redis-on-pagewalk-retry-20260629-051036/timings.csv`
- Redis-disabled CSV: `data/development/benchmark-runs/redis-off-pagewalk-msp-20260629-054028/timings.csv`

Runtime verification:

- Redis-enabled services were restored after benchmarking; `account-service` container env verified as `GLOBAL_IAM_DEMO_USE_REDIS=true`.
- Redis-disabled benchmark was run after force-recreating `account-service`, `authorization-service`, and `organization-service`; each container env was verified as `GLOBAL_IAM_DEMO_USE_REDIS=false`.
- `authorization-service` specs for Redis-enabled reflected grants and Redis-disabled MSP direct authorization passed: `9 examples, 0 failures`.

All benchmarked GraphQL requests in the tables below returned HTTP 200.

## GraphQL Timings

Times are `curl` `time_total` values in seconds. Lower is better. Fanout rows are full `mspUserManagement` page walks, not first-page probes.

| Phase | Query | Redis on | Redis off | Delta off-on |
| --- | ---: | ---: | ---: | ---: |
| startup cold | deep chain | 0.566 | 2.348 | +1.782 |
| startup cold | wide org | 3.432 | 4.012 | +0.579 |
| startup cold | dense account | 10.675 | 11.597 | +0.922 |
| startup cold | 100k MSP fanout | 105.321 | 109.786 | +4.465 |
| startup cold | 50k MSP fanout | 55.914 | 55.036 | -0.877 |
| startup cold | 10k MSP fanout | 11.501 | 11.592 | +0.091 |
| cold after startup | deep chain | 0.398 | 0.561 | +0.163 |
| cold after startup | wide org | 3.382 | 3.582 | +0.199 |
| cold after startup | dense account | 11.484 | 11.431 | -0.053 |
| cold after startup | 100k MSP fanout | 109.588 | 104.723 | -4.865 |
| cold after startup | 50k MSP fanout | 55.440 | 56.848 | +1.408 |
| cold after startup | 10k MSP fanout | 11.516 | 11.378 | -0.137 |
| warm | deep chain | 0.502 | 0.576 | +0.074 |
| warm | wide org | 3.740 | 3.717 | -0.023 |
| warm | dense account | 11.911 | 11.709 | -0.202 |
| warm | 100k MSP fanout | 110.355 | 109.016 | -1.340 |
| warm | 50k MSP fanout | 55.525 | 55.119 | -0.406 |
| warm | 10k MSP fanout | 11.503 | 11.533 | +0.030 |

## Fanout Validation

| Query | Redis on pages/accounts | Redis off pages/accounts |
| --- | ---: | ---: |
| 100k MSP fanout | 20 pages / 99,999 accounts | 20 pages / 99,999 accounts |
| 50k MSP fanout | 10 pages / 49,999 accounts | 10 pages / 49,999 accounts |
| 10k MSP fanout | 2 pages / 9,999 accounts | 2 pages / 9,999 accounts |

## Notes

- The previous fanout benchmark rows were invalid because they measured first-page/loading behavior. The current fanout rows page-walk through `continuance` like the MSP UI.
- `startup cold` includes service warmup costs. `cold after startup` repeats after the system is warm; for Redis-enabled runs the benchmark flushes Redis before this phase. For Redis-disabled runs there is no Redis cache to flush.
- MSP no-cache now works by checking the actor's native MSP user-management grant directly and authorizing the requested managed-account page without Redis.
- With full fanout page walks, Redis-on and Redis-off timings are close. The dominant cost is fetching and serializing the full user/group payload for each MSP page, not the reflected-grant lookup.
