# Showcase trace refresh — 2026-09-11

Ran `ruby scripts/refresh_article_traces.rb` against production, rebuilding the current working tree. All 13 traces archived; 12 requests/workloads passed and the wide-capabilities request returned the known empty reply (curl 52). The runner exits successfully for that expected failure; it is not a successful timing sample.

Raw collection: `raw/article-traces-20260911T210515Z/`. See its `trace-index.json` for trace IDs and paths and `showcase-timings.json` for numeric data.

These are single showcase samples, not a replacement benchmark matrix. Trace elapsed time is the interval from the earliest span start to the latest span end, including gaps between requests for multi-request workloads. It is not client latency. Client timings are available only for the hierarchy workloads. Organization/MSP requests collect the first page only. Authorization rows are full source traces; subtree roots must be selected before importing excerpts.

| Showcase source | Trace elapsed (s) | Client elapsed (s) | Spans | Outcome |
| --- | ---: | ---: | ---: | --- |
| hierarchy-walk | 0.371902 | 0.374334 | 410 | ok |
| hierarchy-cte | 0.156829 | 0.157968 | 104 | ok |
| hierarchy-individual | 0.554524 | 0.556131 | 832 | ok |
| hierarchy-batch | 0.081010 | 0.082662 | 105 | ok |
| authorization-record-can | 1.167596 | 1.168800 | 1,827 | ok |
| authorization-record-capabilities | 19.721088 | — | 48,812 | ok |
| authorization-collection-capabilities | 34.459219 | — | 98,987 | transport_error |
| authorization-collection-can | 2.883931 | — | 885 | ok |
| organization-cold | 1.469128 | — | 489 | ok |
| organization-warm | 0.938046 | — | 368 | ok |
| graphql-cold | 0.429538 | — | 270 | ok |
| graphql-warm | 0.162700 | — | 154 | ok |
| graphql-msp | 0.328408 | — | 160 | ok |

Seed workers were stopped for collection. The runner leaves the final production profile running: `/can`, Redis enabled, batched retrieval, batch size 200. Existing historical exports were preserved.
