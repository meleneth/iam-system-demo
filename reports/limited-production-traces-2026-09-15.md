# Limited production trace inspection — 2026-09-15

Production was seeded with 15,526 users using `DEMO_SEED_PROFILE=limited`: deep_chain (500), wide_org (5,020), massive_fanout_10k (10,000), and trace_isolation_msp (6). Seed queues drained and seed workers were stopped.

[Production Jaeger: named workloads](http://localhost:11290/search?service=trace-workloads)

All 13 traces were archived and passed trace-structure validation. Twelve requests succeeded. The wide capabilities request failed with curl exit 52 (empty reply), despite a downstream HTTP 200; its workload root records the transport error. These are inspection samples, not large-dataset benchmark results.

Workload roots identify intent, fixture and user count, authorization mode, Redis phase, retrieval mode, and batch size. HTTP operations identify actual returned record counts. GraphQL server spans include `graphql.document`. Redis spans retain actual pipelines and omit standalone command and fine-grained cache spans. All six service Gemfiles declare tsort.

Code commits: limited seed `f888fd6`, GraphQL documents `233be7e`, tsort `940e6bb`, request names and pipeline tracing `f8dff5a`, workload roots `60e72fb`.

## Trace index

| Workload | Outcome | Spans | Jaeger |
| --- | --- | ---: | --- |
| Walk 5 parent accounts  /  limited/deep_chain (500 users)  /  can  /  Redis off  /  batched 1000 | ok | 106 | [Open](http://localhost:11290/trace/0e2c5cc6b34eb1b236cd0204868cd53a) |
| Load 5-level hierarchy with CTE  /  limited/deep_chain (500 users)  /  can  /  Redis off  /  batched 1000 | ok | 47 | [Open](http://localhost:11290/trace/31453185e7ed3416ee5c00a54a59e413) |
| Load 8 hierarchies individually  /  limited/deep_chain (500 users)  /  can  /  Redis off  /  batched 1000 | ok | 369 | [Open](http://localhost:11290/trace/e1f1c6885f3bd1e6a9f6ecb3e8cadd49) |
| Load 8 hierarchies in one batch  /  limited/deep_chain (500 users)  /  can  /  Redis off  /  batched 1000 | ok | 47 | [Open](http://localhost:11290/trace/a46737382feef0e7fad3ec889152fb53) |
| Walk 25 parent accounts  /  limited/deep_chain (500 users)  /  can  /  Redis off  /  batched 1000 | ok | 526 | [Open](http://localhost:11290/trace/d567559b2f7d534c53019042f61a1f15) |
| Load organization users and groups  /  limited/deep_chain (500 users)  /  capabilities  /  Redis off  /  serial 1000 | ok | 14262 | [Open](http://localhost:11290/trace/fc8ba4d4f38b0728146910d179259406) |
| Load organization users and groups  /  limited/wide_org (5020 users)  /  capabilities  /  Redis off  /  batched 1000 | transport_error | 28184 | [Open](http://localhost:11290/trace/ca8467e5008494897103ca0ef4c3e623) |
| Load organization users and groups  /  limited/wide_org (5020 users)  /  can  /  Redis off  /  batched 1000 | ok | 226 | [Open](http://localhost:11290/trace/92c99b5ec4ae72ae386ee767527f6057) |
| Load organization users and groups  /  limited/wide_org (5020 users)  /  can  /  Redis cold  /  batched 1000 | ok | 123 | [Open](http://localhost:11290/trace/975b8ca4c8a8ab14d6be12c8d442cc2f) |
| Load organization users and groups  /  limited/wide_org (5020 users)  /  can  /  Redis warm  /  batched 1000 | ok | 87 | [Open](http://localhost:11290/trace/4e1441b8abb4afda8eeaeadc3c5750d7) |
| GraphQL hierarchy users and groups  /  limited/deep_chain (500 users)  /  can  /  Redis cold  /  batched 1000 | ok | 99 | [Open](http://localhost:11290/trace/d1ba6819bc8da01170ee4cf0eeb7e1f5) |
| GraphQL hierarchy users and groups  /  limited/deep_chain (500 users)  /  can  /  Redis warm  /  batched 1000 | ok | 48 | [Open](http://localhost:11290/trace/3e202301024136032a401dfff5bc7250) |
| GraphQL MSP users and groups  /  limited/massive_fanout_10k (10000 users)  /  can  /  Redis warm  /  batched 200 | ok | 247 | [Open](http://localhost:11290/trace/f15512e6b051c8ce6ca4bb5b4764eb98) |

## Evidence

- [Machine-readable index with archive hashes](summary/limited-production-traces-2026-09-15.json)
- [Raw collection](raw/limited-traces-20260915/named-collection/)
- [Trace validation](raw/limited-traces-20260915/named-collection/reduced-trace-validation.json)
- [Collection failure details](raw/limited-traces-20260915/named-collection/collection_status.json)
- [Seed log](raw/limited-traces-20260915/seed.log)

Raw artifacts are local and gitignored. The committed index preserves their hashes and Jaeger links.

## Reading the hierarchy authorization checks

In the warm GraphQL hierarchy trace, the first `account.read` check authorizes the single requested starting account before hierarchy lookup. The second checks all 25 returned hierarchy accounts before exposing their records. The starting account overlaps both checks; permission on it does not imply permission on its ancestors. See `AccountsController#accounts_with_parents` and `#authorize_hierarchy_records!`.
