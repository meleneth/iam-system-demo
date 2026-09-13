# Showcase rerun — 2026-09-11 (17:14 PDT)

Ran `ruby scripts/refresh_article_traces.rb` against production, rebuilding the current working tree. All 13 traces archived; 11 samples passed. Both capabilities requests returned empty replies (curl 52). The wide failure is expected by the runner; the deep serial failure is new relative to the earlier collection, so the runner exited 1.

Raw collection: [article-traces-20260912T001449Z](raw/article-traces-20260912T001449Z/). Trace IDs and export paths are in `trace-index.json`; numeric data is in `showcase-timings.json`; failure diagnostics are in the deep serial case directory.

Single showcase samples, not a replacement benchmark matrix. Trace elapsed time spans the earliest start through the latest end, including gaps between requests; it is not client latency. Client timings are available only for hierarchy workloads. Organization/MSP requests collect the first page only. Authorization traces are full sources requiring subtree selection before importing excerpts.

Seed workers were observed running during collection, unlike the earlier run. Their workload was not measured; direct timing comparisons are therefore limited. Final production profile: `/can`, Redis enabled, batched retrieval, batch size 200. Historical exports were preserved.

| Source | Trace elapsed (s) | Client elapsed (s) | Spans | Outcome |
| --- | ---: | ---: | ---: | --- |
| hierarchy-walk | 0.747943 | 0.752538 | 331 | ok |
| hierarchy-cte | 0.136287 | 0.140577 | 85 | ok |
| hierarchy-individual | 1.453958 | 1.457232 | 680 | ok |
| hierarchy-batch | 0.213032 | 0.216398 | 86 | ok |
| authorization-record-can | 2.831201 | 2.835189 | 1,450 | ok |
| authorization-record-capabilities | 34.260460 | — | 39,568 | transport_error |
| authorization-collection-capabilities | 59.462735 | — | 82,728 | transport_error |
| authorization-collection-can | 3.272828 | — | 710 | ok |
| organization-cold | 1.952742 | — | 383 | ok |
| organization-warm | 1.103176 | — | 276 | ok |
| graphql-cold | 0.519197 | — | 211 | ok |
| graphql-warm | 0.249113 | — | 118 | ok |
| graphql-msp | 0.470771 | — | 119 | ok |
