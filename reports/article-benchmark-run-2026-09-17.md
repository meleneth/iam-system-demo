# Full article benchmark run — September 17, 2026

The production article collector ran the complete 17-case matrix at revision
`21f58d0188ea1cebba97d3cfcd01a523edbdfcf0`, using the existing production
fixture manifest. It ran from 07:55:52 to 11:14:53 UTC. Both smoke cases and all
17 per-case authorization correctness gates passed. The collector exited **1**:
12 cases passed and 5 retained failed samples.

Raw evidence is in [article-20260917T075552Z](raw/article-20260917T075552Z/).
Start with [collection status](raw/article-20260917T075552Z/collection_status.json),
then each case's `completed.json`, `attempt-001/timings.csv`, `run.log`, and
trace status files. The raw directory
is gitignored and remains local.

## Failed cases

| Case | Recorded failure |
| --- | --- |
| `retrieval-wide-serial` | All three 251-account Organization walks hit the 180-second client timeout, returning no response. Their traces were also incomplete. |
| `retrieval-wide-batched` | All three 251-account capabilities walks returned an empty reply (`curl` 52) after 42.0–43.6 seconds. |
| `auth-sparse-capabilities` | All three 401-account capabilities walks returned an empty reply (`curl` 52) after 94.7–105.9 seconds. |
| `graphql-redis-off-b10000` | Every measured response passed the response checker and completed its fanout walk, but 5 of 63 Jaeger traces lacked required parent spans. |
| `graphql-cache-b10000` | Every measured response passed the response checker and completed its fanout walk, but 2 of 189 Jaeger traces lacked required parent spans. |

The two 10k fanout cases at batch sizes 1,000 and 200 passed, including all
135 and 504 trace exports respectively. The incomplete traces in the two
10,000-batch cases make those cases failed collector results even though their
response timings and account counts were recorded.

### Why those traces were incomplete

Each of the seven affected Jaeger traces contains child spans whose parent
span is absent. The initiating request span is present. Re-querying Jaeger
after the run returned the same span counts and missing parents, so waiting
longer did not complete them.

The OpenTelemetry collector log has a matching `Exporting failed. Dropping
data.` entry inside each affected request's time window: 09:01:58, 09:04:23,
09:13:37, 09:14:02, 09:24:18, 09:50:23, and 09:57:59 UTC. Jaeger's OTLP gRPC
receiver rejected the export with `ResourceExhausted`: the decompressed message
exceeded its 4,194,304-byte receive limit. The collector treated this as a
permanent error and dropped each rejected batch (39–64 items in the matching
log entries). The logs do not identify individual span IDs, but the timing and
persistently missing spans support this as the cause of the trace gaps. The
collector currently uses a default `batch: {}` processor before its Jaeger
OTLP exporter; see [collector configuration](../otel-collector/otel-collector-config.yaml).

## Selected measured client times

Values below are medians of three complete-walk samples in seconds. Redis-on
`cold` samples flush Redis before the complete workload. Redis-off samples run
with Redis disabled. `Warm` means that same complete workload was primed
immediately before measurement. Times exclude trace export and priming.

| Workload | Redis off, cold | Redis on, cold | Redis on, warm |
| --- | ---: | ---: | ---: |
| MSP 100k fanout, batch 10,000 | 244.04 | 63.44 | 37.40 |
| MSP 50k fanout, batch 10,000 | 79.04 | 30.15 | 16.05 |
| MSP 10k fanout, batch 10,000 | 8.73 | 5.42 | 2.93 |
| MSP 10k fanout, batch 1,000 | — | 13.56 | 5.06 |
| MSP 10k fanout, batch 200 | — | 31.20 | 24.96 |

All measured fanout walks in this table returned the expected account totals:
99,999, 49,999, and 9,999. The batch-10,000 rows belong to cases failed by
trace archival, so they are response observations rather than passed full-case
results.

The deep-chain Organization walk (25 accounts, Redis off) had medians of
23.67 seconds in serial retrieval and 2.08 seconds in batched retrieval.
The Redis-off `/can` Organization walks passed with medians of 1.99 seconds
for the 251-account wide fixture and 4.07 seconds for the 401-account sparse
fixture. The wide and sparse capabilities failures prevent a successful
authorization-mode comparison at those sizes.

This collection ran the benchmark's sampled live authorization gate and
response/count checks. It did not perform an independent full returned-identity
audit. The five failed cases prevent treating this as a successful complete
article matrix.
