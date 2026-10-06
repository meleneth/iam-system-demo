# Gallery benchmark rerun — October 5, 2026

The production gallery collector completed all 13 measured examples across seven profiles, with all seven authorization gates passing and no collection failures. Source revision: `5b8cb7bda92d49668ba2e915262b8183985a2498`. Collection began at `2026-10-06T02:30:20Z` (October 5 in America/Los_Angeles).

The collector built the application images and warmed each profile twice before measurement. Cold samples flushed only Redis DB 1; PostgreSQL was not restarted or reseeded. Seed workers stayed stopped during collection. Each example has one measured sample; this run does not replace the repeated benchmark matrix.

| Example | Outcome | Client seconds | Spans |
| --- | --- | ---: | ---: |
| hierarchy-walk | ok | 0.211 | 171 |
| hierarchy-cte | ok | 0.067 | 78 |
| hierarchy-individual | ok | 0.577 | 617 |
| hierarchy-batch | ok | 0.097 | 78 |
| authorization-record-can | ok | 0.787 | 851 |
| authorization-record-capabilities | ok | 16.382 | 24973 |
| authorization-collection-capabilities | ok | 12.994 | 18406 |
| authorization-collection-can | ok | 3.356 | 560 |
| organization-cold | ok | 1.313 | 251 |
| organization-warm | ok | 0.975 | 173 |
| graphql-cold | ok | 0.272 | 169 |
| graphql-warm | ok | 0.192 | 78 |
| graphql-msp | ok | 0.237 | 91 |

`python3 scripts/validate_reduced_traces.py` passed for all 13 exports, checking workload roots, cross-service ancestry, GraphQL query tags, application SQL, and Redis pipelines. Raw evidence is in `reports/raw/article-traces-20261006T023020Z/`, including collection status, trace index, validation results, per-profile correctness gates, responses, timings, and final stack status. Raw evidence is ignored by Git.

Missing eventstream, Grafana, Prometheus, Loki, and Promtail services were started before collection. After measurements, all 20 production seed worker replicas were started through `seed_workers.sh`. The final check found all 50 configured services and 60 containers running, no missing replicas or unhealthy containers, and all nine application readiness endpoints responding successfully.

Production remains in the final gallery profile: `/can`, Redis enabled, batched retrieval, batch size 200. Production Jaeger is [http://localhost:11290/](http://localhost:11290/); the live Docker mapping was verified and the UI returned HTTP 200. Grafana is [http://localhost:11280/](http://localhost:11280/).
