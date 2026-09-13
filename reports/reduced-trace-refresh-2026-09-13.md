# Reduced instrumentation showcase — September 13, 2026

**Superseded:** use [the warmed HTTP/API/SQL collection](warmed-request-traces-2026-09-13.md).
This historical collection omitted HTTP spans and included first-request work; it
does not satisfy the author’s clarified telemetry/warmup requirements.

Collection: [article-traces-20260913T085755Z](raw/article-traces-20260913T085755Z/). All 13 exports archived and passed
`scripts/validate_reduced_traces.py`. Twelve workload requests succeeded; wide
batched capabilities returned an empty reply (curl 52), so the collector exited 1.
The serial capabilities request succeeded this time. The failure is preserved as
observed evidence, with its response/diagnostics and connected trace.

This is a showcase refresh, not a new benchmark matrix. September 10 benchmark
tables remain unchanged. Historical collections remain intact.

## Source and runtime

Base revision: `a11a5c7765a835566015e7f7fcf8b369a8cf8a0b`, plus the archived `working-tree.patch`
(SHA-256 `2655b7a6a8b2b6c3e47fb1a799e7562a7a7594329c8ad4bf8a8baf829da7bb95`).
The patch includes newly added propagation helpers and authorization instrumentation;
`startup-working-tree.patch` retains the initial tracked-only snapshot. Runtime
source was unchanged between build and collection. `build.log`, `final-image-ids.txt`,
per-case `runtime.json`, and `collection.json` record the build and settings.

Automatic tracing now enables PG, Redis, and User Management GraphQL only.
Controller/action, automatic HTTP/Rack, response lifecycle, serialization,
encoding/decoding, payload-building, and materialization spans were removed at
source. Cache-operation spans remain, including pipelines, lookup, hit processing,
and miss loading. Context-only Rack extraction and Net::HTTP injection connect
application spans across services without altering actors or authorization.
Authorization computation spans provide new excerpt roots.

Existing persisted fixtures were reused; no seed jobs were submitted. The stack
was stopped initially. After starting the queue service, all five queues reported
zero visible and in-flight messages (`seed-queues-before.json`). All ten workers
were explicitly stopped before collection and remained exited afterward:
`seed-workers-stop.log`, `worker-state.json`, `final-container-state.json`.
The queue service does not persist messages across restart; queue emptiness here
is a readiness observation, not proof of historical ingestion. Successful fixture
requests provide the live readiness evidence for this collection.

Final profile: `/can`, Redis enabled, batched retrieval, batch size 200.

## Validation and outcomes

Configuration tests: 3 tests / 68 assertions. Archive tests: 3 / 11. Collection
tests: 4 / 16. Integration probes passed for Puma keep-alive, actor/body/baggage,
exceptions and context restoration, Dataloader ancestry, and actual cross-service
Faraday/Net::HTTP propagation with no transport spans. All 13 source exports have
only the known external initiating parent; cross-service parent links remain
intact. Redis and application cache operations remain visible.

These durations are **span envelopes**, not HTTP client latency. Complete source
traces include all recorded work; authorization gallery examples are smaller
selected subtrees. Missing HTTP spans intentionally reduce span totals.

| Source | Outcome | Spans | Redis spans | Envelope (s) |
| --- | --- | ---: | ---: | ---: |
| hierarchy-walk | ok | 101 | 0 | 0.444044 |
| hierarchy-cte | ok | 19 | 0 | 0.080573 |
| hierarchy-individual | ok | 152 | 0 | 0.479568 |
| hierarchy-batch | ok | 19 | 0 | 0.048901 |
| authorization-record-can | ok | 300 | 0 | 1.154564 |
| authorization-record-capabilities | ok | 8018 | 0 | 17.641951 |
| authorization-collection-capabilities | transport_error | 20148 | 0 | 33.643133 |
| authorization-collection-can | ok | 191 | 0 | 2.528405 |
| organization-cold | ok | 108 | 19 | 1.307878 |
| organization-warm | ok | 45 | 9 | 0.787967 |
| graphql-cold | ok | 56 | 15 | 0.312273 |
| graphql-warm | ok | 26 | 5 | 0.130625 |
| graphql-msp | ok | 27 | 4 | 0.364161 |

## Publishing handoff

Target: `/home/meleneth/Documents/whirred-io`. The importer now selects the new
collection and the following roots, retaining every descendant without filtering:

| Example | Root span ID | Root operation | Spans |
| --- | --- | --- | ---: |
| authorization-record-can | `32321ad6873e5ac7` | `authorization.permission.accounts` | 11 |
| authorization-record-capabilities | `a94f02fc7565bba9` | `authorization.capabilities.account` | 21 |
| authorization-collection-capabilities | `57ad2689b9f63e84` | `GroupUser.collection.authorize` | 194 |
| authorization-collection-can | `57038e3eb5ac7049` | `GroupUser.collection.authorize` | 14 |

The collection pair selects group-membership authorization for 19 account scopes:
19 capability computations / ancestry CTEs / membership lookups versus one
19-account permission computation / ancestry CTE / membership lookup. The
single-account excerpts do not assert identical account identity: reduced spans
omit those IDs. Only the wide capabilities source failed; HTTP status is now
harness evidence, not a span attribute.

Importer, 13 JSON exports, both manifests, all SVG previews, gallery comparisons,
README, and viewer were refreshed. Published JSON totals 911,335 bytes. The obsolete
“Before the first outgoing HTTP request” UI, model function, and test were removed.
The README corrects its earlier claim that September 12 omitted controller spans.
Trace-model tests and VitePress build passed. This intermediate gallery was deployed as publishing commit `b6ff56f`; its rollout
evidence is in the raw collection’s `publishing-deployment.json`. It is superseded.
