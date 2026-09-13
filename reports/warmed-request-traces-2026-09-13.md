# Warmed HTTP/API/SQL showcase — September 13, 2026

Collection: [article-traces-20260913T094922Z](raw/article-traces-20260913T094922Z/).
Runtime code was committed before rebuilding: `232d52dc2cac079c367080c66acc6461eab71a3b`.
The tracked working-tree patch is empty. Untracked historical reports were present;
no uncommitted runtime changes were built. Publishing commit:
`3c1ece460aa1c8c4eaed6923bae887f7240ff6dc`.

All 13 measured exports passed validation. Twelve measured requests succeeded.
Wide batched capabilities returned an empty reply (curl 52), at **30.709678 seconds
until failure**. The collector exited 1 for this observed request failure; trace
validation passed. Both of that profile's warmups also returned empty replies;
their traces settled before the next request. The serial capabilities sample
completed with HTTP 200 at **14.449516 seconds** after warming.

This is a refreshed gallery showcase, not a replacement benchmark matrix.
September 10 benchmark tables retain their original measurements. Historical
collections are preserved, including the superseded `article-traces-20260913T085755Z`
and interrupted `article-traces-20260913T094026Z`.

## Telemetry and cache policy

- HTTP client spans cover direct Net::HTTP, Faraday, and ActiveResource requests.
  Rack API spans preserve context and connect downstream SQL to the API call.
- Application SQL is recorded from `sql.active_record`, including the actual SQL
  statement. Schema introspection, catalog queries, setup/SET commands, transaction
  administration, and cached results produce no SQL spans.
- ActiveRecord's per-request query cache **remains enabled**. The database integration
  test confirms two identical lookups yield one executed SQL span and one cache hit.
- Unused Solid Cache was removed from dependencies, production store configuration,
  database roles, and schema files. Live `Rails.cache` is `ActiveSupport::Cache::NullStore`;
  Solid Cache is not loaded. Existing database volumes were not deleted.
- Redis commands/pipelines, cache fetch/lookup/miss operations, authorization, and
  GraphQL/Dataloader work remain. Cache decoding has no separate timing span.
- Controller/action, automatic connect-only spans, custom HTTP phases, response
  lifecycle phases, serialization, and materialization spans are absent at source.
  Actor identity and authorization decisions are unchanged.

## Warmup and runtime evidence

Each profile received two workload warmup passes before its measurements. Hierarchy
passes exercise all five selected variants; their outcomes are saved separately.
Organization/GraphQL warmup traces are archived separately to confirm the preceding
request has settled, including failures. Measured exports exclude warmup requests.

Puma PIDs/start ticks matched before warmup, after warmup, and after measurement
in all seven service roles for every profile. Configuration switches can recreate
Rails before warming; no restart separates warmup, cold Redis, and warm Redis.
Only Redis DB 1 was flushed. PostgreSQL was not flushed or restarted: all **20
PostgreSQL instance identities stayed identical** from the pre-collection snapshot
through the end. All **ten seed workers remained exited**, and all five queues
reported zero visible/in-flight messages at final verification. Existing fixtures
were reused; no new seeding was performed.

Evidence: `postgres-before.txt`, `postgres-after.txt`, `worker-state.json`,
`final-container-state.json`, `seed-queues-after.json`, `runtime-cache-settings.json`,
`final-image-ids.txt`, `build.log`, and each profile's `runtime.json`,
`processes-*.json`, `warmup-results.json`, and Redis flush logs.

Final profile: `/can`, Redis enabled, batched retrieval, batch size 200.

## Measured showcase outcomes

Client time is recorded by curl for organization/GraphQL requests and by the
hierarchy harness's monotonic clock for hierarchy workloads. A failed request's
elapsed time is time until failure, not a successful latency. Span envelopes are
separate values in `reduced-trace-validation.json` and the publishing manifests.
HTTP counts below are instrumented downstream client calls, excluding initiating
harness calls. SQL counts exclude ActiveRecord query-cache hits.

| Source workload | Outcome | Client seconds | Spans | Downstream HTTP | Executed SQL | Redis spans |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| hierarchy-walk | ok | 0.158398 | 95 | 15 | 30 | 0 |
| hierarchy-cte | ok | 0.032933 | 28 | 4 | 8 | 0 |
| hierarchy-individual | ok | 0.399892 | 224 | 32 | 64 | 0 |
| hierarchy-batch | ok | 0.066284 | 28 | 4 | 8 | 0 |
| authorization-record-can | ok | 0.989924 | 475 | 75 | 150 | 0 |
| authorization-record-capabilities | ok | 14.449516 | 12558 | 2302 | 3977 | 0 |
| authorization-collection-capabilities | transport_error | 30.709678 | 28232 | 4042 | 8072 | 0 |
| authorization-collection-can | ok | 1.964786 | 203 | 38 | 64 | 0 |
| organization-cold | ok | 1.147830 | 111 | 23 | 26 | 16 |
| organization-warm | ok | 1.026560 | 86 | 20 | 19 | 9 |
| graphql-cold | ok | 0.333144 | 78 | 12 | 14 | 14 |
| graphql-warm | ok | 0.134170 | 43 | 8 | 5 | 5 |
| graphql-msp | ok | 0.253076 | 44 | 8 | 8 | 4 |

## Authorization subtree handoff

`authorization-subtrees.json` records roots, scope identity, HTTP paths/counts,
and SQL operation counts. The single-record pair identifies the same account
through `scope.id`. The collection pair authorizes the identical GroupUser API
lookup across 19 account scopes; its enclosing request target was compared exactly.

| Gallery example | Root span ID | Spans | Subtree seconds |
| --- | --- | ---: | ---: |
| authorization-record-can | `e5a0289e74e4b029` | 15 | 0.014548 |
| authorization-record-capabilities | `503e35eb6690738f` | 15 | 0.012787 |
| authorization-collection-capabilities | `21640c11321c4923` | 272 | 0.256390 |
| authorization-collection-can | `4c164a4bd9b9da5d` | 20 | 0.039175 |

The collection capabilities call performs 19 `POST /accounts_with_parents` calls
and 19 `POST /organization_account_ids/for_account_ids` calls. The matching
`POST /can/Account/account.users.read` performs one of each. The selected local
roots are `GroupUser.collection.authorize`; all descendants are preserved.

## Validation and publishing

Source checks passed: configuration (4 tests / 118 assertions), warmed collection
protocol (2 / 7), trace archive (3 / 11), and collection harness (4 / 16). Integration
checks passed for Dataloader context (1 / 10), real Puma API requests (2 / 23),
direct/Faraday/ActiveResource requests (1 / 19), application SQL and query caching
(1 / 9), and Rack response/body context cleanup. Source-export validation confirms
HTTP/API ancestry, SQL under API calls, cache visibility, and no removed categories.

Publishing importer, all 13 JSON examples, both manifests, SVG previews, gallery
captions, and scripts README were updated. Published trace JSON totals **1,809,282
bytes**. The viewer derives readable HTTP endpoint labels from recorded tags,
displays the full executed SQL, and reports client elapsed time separately from
span/subtree duration. It retains the earlier removal of the obsolete pre-HTTP
diagnostic. Raw span objects and queries are preserved without span filtering.
Four trace-model tests and the VitePress build passed. The deployment image was
built from the publishing commit, excluding unrelated working-tree edits.
Deployment verification is recorded below after rollout.
