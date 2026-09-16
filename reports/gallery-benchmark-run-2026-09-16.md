# Gallery benchmark run — September 16, 2026

The production gallery collector `ruby scripts/refresh_article_traces.rb` ran at
source revision `6a6a41e911c1b0ed018b0f36831fc879e5d98fd2` using the existing
full-profile fixture manifest. It rebuilt the application images, started the
production infrastructure, warmed each of seven configurations twice, and
archived all 13 measured traces. No seed workers were running. All seven
authorization correctness gates passed.

The collector exited **1** because the wide, batched capabilities request
returned an empty reply (`curl` exit 52, HTTP status 0) after 44.639 seconds.
That trace is diagnostic evidence, not a successful latency sample. The other
12 measured examples succeeded. The same request failed in previous gallery
collections; this run does not establish the cause of the empty reply.

| Gallery example | Outcome | Client seconds | Spans |
| --- | --- | ---: | ---: |
| hierarchy-walk | ok | 0.155 | 106 |
| hierarchy-cte | ok | 0.072 | 47 |
| hierarchy-individual | ok | 0.666 | 369 |
| hierarchy-batch | ok | 0.088 | 47 |
| authorization-record-can | ok | 0.991 | 526 |
| authorization-record-capabilities | ok | 21.550 | 14,262 |
| authorization-collection-capabilities | transport error | 44.639 | 28,296 |
| authorization-collection-can | ok | 1.962 | 226 |
| organization-cold | ok | 1.199 | 123 |
| organization-warm | ok | 0.813 | 87 |
| graphql-cold | ok | 0.346 | 99 |
| graphql-warm | ok | 0.192 | 48 |
| graphql-msp | ok | 0.520 | 247 |

`python3 scripts/validate_reduced_traces.py` passed for all 13 exports. It
checked workload roots, cross-service ancestry, GraphQL query tags, application
SQL, Redis pipeline spans, and absence of removed instrumentation categories.

Evidence is in
[`reports/raw/article-traces-20260916T115616Z`](raw/article-traces-20260916T115616Z/):
`collection_status.json`, `trace-index.json`, `reduced-trace-validation.json`,
per-example `result.json` and `trace.json`, and the failed request's
`failure.json` and `failure-services.log`. The final configuration remains
running: `/can`, Redis enabled, batched retrieval, batch size 200.

This is a gallery showcase with one measured example per scenario. It does not
replace the full article benchmark matrix or provide repeated-run statistics.
