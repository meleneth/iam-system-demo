# Gallery benchmark run — September 29, 2026

The production gallery collector ran at source revision `75c3c38b8933f510f4408ab244ccf675098b4a19`
from 20:19:44 to 20:34:17 UTC (13:19–13:34 America/Los_Angeles). It rebuilt
the application images, warmed each of seven profiles twice, and collected
all 13 measured examples against the existing full fixture set. Seed workers
were stopped during collection. PostgreSQL was not restarted or reseeded; cold
samples flushed only Redis DB 1. The new request and infrastructure telemetry
was enabled throughout this run.

**Result: 11 successful measurements and two transport errors.** The collector
exited 1 because both capabilities-mode requests returned empty replies
(`curl` exit 52, HTTP status 0). Their durations below describe failed requests,
not successful latency samples. The same failure type occurred in earlier
gallery runs; this collection does not establish its cause.

| Gallery example | Outcome | Client seconds | Spans |
| --- | --- | ---: | ---: |
| hierarchy-walk | ok | 0.530 | 171 |
| hierarchy-cte | ok | 0.238 | 78 |
| hierarchy-individual | ok | 1.845 | 617 |
| hierarchy-batch | ok | 0.172 | 78 |
| authorization-record-can | ok | 2.554 | 851 |
| authorization-record-capabilities | transport error | 88.002 | 24,973 |
| authorization-collection-capabilities | transport error | 54.229 | 18,406 |
| authorization-collection-can | ok | 4.919 | 560 |
| organization-cold | ok | 2.341 | 251 |
| organization-warm | ok | 1.690 | 173 |
| graphql-cold | ok | 0.792 | 169 |
| graphql-warm | ok | 0.449 | 78 |
| graphql-msp | ok | 0.560 | 91 |

All seven authorization correctness gates passed. Successful request samples
passed their fixture identity checks. `python3 scripts/validate_reduced_traces.py`
validated all 13 archived traces, including workload roots, cross-service
ancestry, GraphQL query tags, application SQL, and Redis pipeline spans.

The run is visible in Grafana with its time range selected:

- [Web requests](http://localhost:11280/d/iam-web-requests?from=1790713184000&to=1790714057231)
- [PostgreSQL](http://localhost:11280/d/iam-postgresql?from=1790713184000&to=1790714057231)
- [Redis](http://localhost:11280/d/iam-redis?from=1790713184000&to=1790714057231)

The application stack remains in the final gallery profile: `/can`, Redis
enabled, batched retrieval, and batch size 200. The previously running seed
workers were restored after collection.

Raw evidence is in `reports/raw/article-traces-20260929T201944Z/`, including `collection_status.json`,
`trace-index.json`, `reduced-trace-validation.json`, per-profile correctness
gates, measured results, and failure diagnostics. This directory is intentionally
ignored by Git.

This gallery run has one measured sample per example; it does not replace
the full repeated-run benchmark matrix.
