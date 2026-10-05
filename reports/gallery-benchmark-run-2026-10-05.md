# Gallery benchmark run — October 5, 2026

Production collection completed all 13 gallery examples successfully across seven profiles, with all seven authorization gates passing. Each profile received two warmups. Cold samples flushed Redis DB 1; PostgreSQL was not restarted or reseeded. These are single samples per example, not a repeated benchmark matrix.

| Example | Outcome | Workload seconds | Spans |
| --- | --- | ---: | ---: |
| hierarchy-walk | ok | 0.131 | 171 |
| hierarchy-cte | ok | 0.054 | 78 |
| hierarchy-individual | ok | 0.541 | 617 |
| hierarchy-batch | ok | 0.092 | 78 |
| authorization-record-can | ok | 0.602 | 851 |
| authorization-record-capabilities | ok | 16.777 | 24973 |
| authorization-collection-capabilities | ok | 12.920 | 18406 |
| authorization-collection-can | ok | 3.065 | 560 |
| organization-cold | ok | 1.460 | 251 |
| organization-warm | ok | 1.013 | 173 |
| graphql-cold | ok | 0.221 | 169 |
| graphql-warm | ok | 0.158 | 78 |
| graphql-msp | ok | 0.251 | 91 |

`scripts/validate_reduced_traces.py` passed for all 13 exports. Evidence is split between `reports/raw/article-traces-20261005T223027Z/` (first ten examples) and `reports/raw/article-traces-20261005T223755Z/` (final three). The initial collector stopped at the GraphQL warmup process-stability check: a temporary Rails runner used to resolve SQL context was present in the initial process snapshot and exited before the later snapshot. The final two profiles were rerun without that probe, reusing the same built images.

Prod remains running in the final profile: `/can`, Redis enabled, batched retrieval, batch size 200. Seed workers were not started.

SQL examples in `examples/sql/`:

- `gallery-auth-grant-lookup.sql`: the actual service grant lookup shape with a small batch of concrete verified inputs; returns the wide-org root scope.
- `gallery-auth-grant-lookup-captured.sql`: verbatim SQL captured from the gallery trace for the full wide-org account batch.
- `gallery-batched-auth-tableplus.sql`: diagnostic reconstruction returning four per-account decisions; verified three allowed and one denied.
- `gallery-batched-auth.sql`: diagnostic reconstruction including MSP inheritance; eight decisions, six allowed and two denied, all matching the service snapshot. Actual results are in `gallery-batched-auth-results.csv`.

The service resolves memberships and ancestry through other services, looks up grants in the auth DB, then maps matching grant scopes back to requested accounts in Ruby. The diagnostic SQL moves that final mapping into SQL using a verified context snapshot. Redis hits can skip the grant lookup. TablePlus connected successfully to the prod auth DB at `127.0.0.1:11330`; the user is handling connection persistence.
