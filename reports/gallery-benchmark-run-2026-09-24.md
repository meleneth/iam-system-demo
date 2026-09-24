# Gallery benchmark run — September 24, 2026

The production stack was rebuilt at source revision
`4e00444fc2b6bd11bf2ec1489422590eb5390bfb`, then the gallery collector ran
with `SKIP_BUILD=1` against those images. It warmed each of seven profiles
twice and archived all 13 measured traces.

| Gallery example | Outcome | Client seconds | Spans |
| --- | --- | ---: | ---: |
| hierarchy-walk | ok | 0.309 | 171 |
| hierarchy-cte | ok | 0.080 | 78 |
| hierarchy-individual | ok | 0.837 | 617 |
| hierarchy-batch | ok | 0.097 | 78 |
| authorization-record-can | ok | 1.112 | 851 |
| authorization-record-capabilities | expected transport error | 30.946 | 27,748 |
| authorization-collection-capabilities | expected transport error | 89.648 | 84,519 |
| authorization-collection-can | ok | 4.725 | 646 |
| organization-cold | ok | 1.761 | 331 |
| organization-warm | ok | 1.402 | 250 |
| graphql-cold | ok | 0.368 | 184 |
| graphql-warm | ok | 0.213 | 93 |
| graphql-msp | ok | 0.712 | 99 |

The two capabilities-mode requests returned empty replies (`curl` exit 52,
HTTP status 0), as expected for these gallery profiles. Their elapsed times are
diagnostic failure durations, not successful latency samples. The other 11
measurements succeeded.

`python3 scripts/validate_reduced_traces.py` passed for all 13 exports. It
validated workload roots, cross-service ancestry, GraphQL query tags,
application SQL, Redis pipeline spans, and the absence of removed
instrumentation categories.

Raw evidence is in
`reports/raw/article-traces-20260924T213536Z/`, including
`collection_status.json`, `trace-index.json`,
`reduced-trace-validation.json`, and each example's result and trace files.
The raw evidence directory is intentionally ignored by Git.
