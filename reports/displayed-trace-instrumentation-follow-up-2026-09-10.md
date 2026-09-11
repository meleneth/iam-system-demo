# Displayed trace gap audit and instrumentation follow-up — 2026-09-10

Status: audit complete; application instrumentation implemented; controlled replay and ingress attribution outstanding. See [implementation and validation](trace-instrumentation-implementation-2026-09-10.md). This note records gaps in instrumentation coverage, not a diagnosis of the latency cause. The selected browser bars match the archived timestamps.

## First reproduce this exact request

The exact example raised during article review: [account-service HTTP POST, span `843e65c2cc85b9db`](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=authorization-collection-capabilities&span=843e65c2cc85b9db).

- Source revision: `c4752dcbff5cf99de65ee3bd846563a302289bde`.
- Collection: `reports/raw/article-no-x-20260910T011818Z/`.
- Case: `retrieval-wide-batched`, attempt 001, first measured cold-after-Redis-flush organization partition request; Redis actually disabled in runtime.json, capabilities authorization, retrieval batched, batch size 1000. Preserve those settings for the reproduction.
- Raw trace: `retrieval-wide-batched/attempt-001/traces/cold_after_redis_flush-organization_user_management_partition_1_page_1.json` within that collection.
- Trace ID: `f0c3a4723a2eb0186f040ef52dd0ed08`.
- Published example: `authorization-collection-capabilities`; complete subtree root `a854eb5598d0170c` (`POST /capabilities/Account`), 211 of 22,212 source spans. This is the authorization call beneath the final `POST /group_users/search` of the successful wide batched run.
- Caller parent: `85638eea0c46f2fd`, `POST /accounts_with_parents`, with `http.host=account-auth-service`.
- Client: `843e65c2cc85b9db`, `service.name=account-service`, `HTTP POST`, Faraday / `Faraday::Adapter::NetHttp`.
- Actual target: `http://organization-service/organization_account_ids/for_account_ids` (POST).
- Downstream Rack server: `a0a8b61cbd7b7c66`, `organization-service`, `POST /organization_account_ids/for_account_ids`.

| Boundary | Raw Jaeger timestamp (microseconds since epoch) | Offset from client start |
| --- | ---: | ---: |
| Client starts | 1789060528633271 | 0.000 ms |
| Organization server starts | 1789060528670750 | 37.479 ms |
| Organization server ends | 1789060528673262 | 39.991 ms |
| Client ends | 1789060528674246 | 40.975 ms |

The 40.975 ms client span contains 37.479 ms before the server span, 2.512 ms inside the server span, and 0.984 ms afterward. About 91.5% precedes the downstream Rack span. The original span objects and the published subtree agree exactly. Do not report the 37.479 ms as known idle time, network transit, queueing, or a TCP issue; its attribution is unknown.

The source trace does not record this POST's exact account-ID body or caller identity. It gives the exact route and the enclosing benchmark case, so obtain the exact payload from a controlled reproduction of that case instead of inventing the IDs or changing the actor.

## Instrument the boundary before changing behavior

1. **Client phases:** in [OrganizationAccount.account_ids_for_organizations_by_account_ids](../account-service/app/models/organization_account.rb), retain the existing Faraday HTTP span and add monotonic-duration events or child spans around request construction/JSON encoding, connection acquisition/reestablishment, DNS/connect where accessible, request header/body writes, first response headers/byte, full response-body read, and subsequent JSON parsing. Log connection reuse, payload/response byte counts, and bounded scope counts. Use instrumentation supported by the actual adapter; do not put labels such as “queue wait” around an interval whose boundaries were not measured.
2. **Arrival before Rack:** inspect the real ingress chain for `organization-service:80` before assuming its Rack span begins at socket arrival. The service Dockerfiles start `./bin/thrust ./bin/rails server`; capture proxy receive/forward, upstream connection, request-body availability, application-server queue entry/dequeue, and earliest Rack entry where supported. Correlate phases with trace/request IDs. A new controller-only span starts too late to explain the 37.479 ms pre-Rack gap.
3. **Server phases:** in [OrganizationAccountsController#for_accounts](../organization-service/app/controllers/organization_accounts_controller.rb), split authorization, parameter/body parsing, membership lookup/materialization, cache lookup/decode, response construction/serialization, and response emission. Keep SQL spans and existing trace context.
4. **Process identity:** [The account initializer](../account-service/config/initializers/opentelemetry.rb) assigns the shared service name `account-service`. The recorded runtime routes authorization's account lookup requests to the separate `account-auth-service` role. Add `service.instance.id` or equivalent container/process identity plus deployment role and connection peer fields, so the account and account-auth processes remain distinguishable. Do not infer the identity from `service.name` alone.
5. **GraphQL context:** audit the active OpenTelemetry parent across resolver/Dataloader fiber boundaries. Several execute-multiplex spans overlap source/HTTP spans that are recorded as siblings rather than descendants. Verify intended parentage before changing it; do not reparent existing evidence in the viewer just because time intervals overlap.
6. **Preserve semantics:** keep the same fixture, actor, authorization mode, Redis mode and batch size while adding instrumentation. Never convert real-actor calls into `IAM_SYSTEM` or `IAM_SYSTEM_AUTH` to improve a reproduction. Preserve the repository scoped internal authorization-routing model described in AGENTS.md.

Also correlate monotonic elapsed times with trace wall-clock times. None of the observed gaps alone proves a clock, scheduling, transport, or pool issue. If phase timings isolate time between writes and receipt, then consider a targeted transport capture; do not jump from an approximately 40 ms duration directly to a delayed-ACK/Nagle diagnosis.

## Scope and method

Audited all 13 currently published examples: 9 complete exports and 4 complete subtrees, 986 spans, 170 directly linked HTTP client/server pairs. Verified each public file against its selection-manifest SHA-256; read only the small published payloads and the source archive-status sidecars. The enclosing multi-megabyte source traces were not part of the broad scan. The client and server spans from the original review question were separately verified against the full original export.

For each directly linked client/server pair, measured `server.start - client.start` and `client.end - server.end`. The 10 ms threshold is an investigation heuristic applied to these samples, not an SLO, percentile or regression criterion. Retain every pair in the JSON report so a different threshold can be applied later.

Also measured time outside the union of each nonclient span's direct-child intervals (clipped to the parent). Flagged at least 10 ms and at least 50% uncovered. This is a coverage inventory, **not exclusive CPU/self time**: named leaf operations can be doing useful work throughout; work may be recorded under siblings; logs are point events, not duration intervals. Do not add parent/child or nested client timings together. Selection is illustrative and small, so finding counts do not estimate production prevalence.

Browser verification covered all 986 bars at 1× and 4× zoom (1,972 checks). Every row shared the same time origin, and starts/widths matched raw timestamps to within 1 px. Tiny spans are intentionally drawn at a minimum width of 2 px; use numerical duration labels for their actual duration. No clock-skew correction is applied. No malformed trees, unexpected absent parents, or child intervals outside parents were found. The 24 external-parent references are all explained: 20 harness-only, 3 excerpt-only, and 1 both. The benchmark injects a synthetic `traceparent` but does not export that initiating span; archive sidecars identify it. Subtree extraction retains original parent references outside the excerpt.

## Every displayed example

“Pre”/“post” count linked HTTP pairs with at least 10 ms before/after the server span. “Coverage” counts nonclient spans passing the coverage heuristic.

| Example | Spans | HTTP pairs | Pre | Post | Max pre ms | Max post ms | Coverage |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hierarchy-walk` | 88 | 15 | 1 | 0 | 20.520 | 3.384 | 0 |
| `hierarchy-cte` | 25 | 4 | 0 | 0 | 3.477 | 1.148 | 1 |
| `hierarchy-individual` | 179 | 32 | 1 | 0 | 28.004 | 0.708 | 0 |
| `hierarchy-batch` | 25 | 4 | 1 | 0 | 20.934 | 2.452 | 0 |
| `organization-cold` | 158 | 23 | 2 | 1 | 11.772 | 11.885 | 7 |
| `organization-warm` | 90 | 20 | 0 | 0 | 5.242 | 9.831 | 8 |
| `graphql-cold` | 76 | 12 | 0 | 0 | 5.869 | 4.032 | 4 |
| `graphql-warm` | 42 | 8 | 1 | 0 | 53.588 | 2.610 | 4 |
| `graphql-msp` | 34 | 6 | 0 | 0 | 5.425 | 2.208 | 1 |
| `authorization-record-capabilities` | 28 | 3 | 0 | 0 | 3.418 | 0.583 | 0 |
| `authorization-record-can` | 17 | 3 | 0 | 0 | 2.627 | 0.556 | 0 |
| `authorization-collection-capabilities` | 211 | 38 | 1 | 0 | 37.479 | 1.231 | 0 |
| `authorization-collection-can` | 13 | 2 | 0 | 0 | 5.310 | 2.724 | 1 |

## HTTP gaps needing attribution

Seven pre-server gaps and one post-server gap pass 10 ms. All 170 outgoing HTTP spans have a directly linked server span in the displayed selection. The table links directly to the client spans; their downstream span IDs and complete timings are in the JSON report.

| Example / client span | Destination | Before server ms | Server ms | After server ms |
| --- | --- | ---: | ---: | ---: |
| `hierarchy-walk` / [1b4dfda072b29803](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=hierarchy-walk&span=1b4dfda072b29803) | authorization-service · `/can/Account/account.read` | 20.520 | 21.555 | 0.584 |
| `hierarchy-individual` / [64e9dde03533c7a8](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=hierarchy-individual&span=64e9dde03533c7a8) | organization-service · `/organization_account_ids/for_account_ids` | 28.004 | 1.609 | 0.578 |
| `hierarchy-batch` / [cf725f20007f4736](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=hierarchy-batch&span=cf725f20007f4736) | authorization-service · `/can/Account/account.read` | 20.934 | 17.222 | 0.339 |
| `organization-cold` / [8b7c13f022fb7355](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=8b7c13f022fb7355) | authorization-service · `/can/Account/account.users.read` | 11.120 | 3.072 | 0.578 |
| `organization-cold` / [6f767c8de9f4b623](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=6f767c8de9f4b623) | authorization-service · `/can/Account/account.read` | 11.772 | 32.660 | 0.576 |
| `organization-cold` / [1a3ae879702eab11](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=1a3ae879702eab11) | user-service · `/users/search` | 1.460 | 452.625 | 11.885 |
| `graphql-warm` / [f7f9ca0b2dbafe0a](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-warm&span=f7f9ca0b2dbafe0a) | authorization-service · `/can/Account/account.read` | 53.588 | 1.288 | 0.607 |
| `authorization-collection-capabilities` / [843e65c2cc85b9db](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=authorization-collection-capabilities&span=843e65c2cc85b9db) | organization-service · `/organization_account_ids/for_account_ids` | 37.479 | 2.512 | 0.984 |

Prioritize the original capabilities path plus warm GraphQL client `f7f9ca0b2dbafe0a`: its 53.588 ms pre-server gap dominates a 55.483 ms HTTP call whose authorization handler spans only 1.288 ms. The cold organization user-service call has 11.885 ms after the server span; response transmission/read/decode boundaries need explicit timing there. A subthreshold example is not proof of complete instrumentation.

## Application coverage and parentage candidates

All 26 flagged nonclient spans are listed below. Five are named `connect` leaves and two are named view-rendering leaves: their lack of child spans is not itself a defect. Remaining rows are candidates for materialization/serialization, endpoint phase, and trace-context instrumentation. “Sibling overlap” identifies time uncovered by children but overlapping recorded sibling spans; it is evidence of concurrent/adjacent span coverage, not proof of a semantic parent-child relationship.

| Example / span | Operation | Duration ms | Outside children ms | Sibling overlap ms |
| --- | --- | ---: | ---: | ---: |
| `hierarchy-cte` / [516a6e7b9b746bdb](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=hierarchy-cte&span=516a6e7b9b746bdb) | organization-service · `POST /organization_account_ids/for_account_ids` | 15.871 | 14.940 | 0.000 |
| `organization-cold` / [399c58ff7285e0c2](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=399c58ff7285e0c2) | account-service · `POST /accounts_with_parents` | 246.836 | 168.456 | 0.000 |
| `organization-cold` / [2347d0969fc30397](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=2347d0969fc30397) | user-management-service · `render_partial.action_view` | 80.892 | 80.892 | 0.000 |
| `organization-cold` / [34ad5cdbddfd0bb5](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=34ad5cdbddfd0bb5) | account-service · `POST /accounts/search` | 128.737 | 72.696 | 0.000 |
| `organization-cold` / [e5be17acde0da51d](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=e5be17acde0da51d) | organization-service · `GET /organization_accounts` | 79.515 | 47.327 | 0.000 |
| `organization-cold` / [cc2750219426667e](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=cc2750219426667e) | organization-service · `POST /organization_account_ids/for_account_ids` | 36.298 | 25.678 | 0.000 |
| `organization-cold` / [c055685a9497a285](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=c055685a9497a285) | user-service · `User query` | 24.691 | 17.228 | 0.000 |
| `organization-cold` / [0fef1a52aac33255](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-cold&span=0fef1a52aac33255) | authorization-service · `GET /can/:scope_type/:permission` | 20.868 | 16.496 | 0.000 |
| `organization-warm` / [edfe4e0000ae2029](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=edfe4e0000ae2029) | user-service · `POST /users/search` | 191.101 | 123.204 | 0.000 |
| `organization-warm` / [05587d24b7aa8c66](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=05587d24b7aa8c66) | user-service · `User query` | 57.187 | 50.851 | 0.000 |
| `organization-warm` / [d7292959201c76e8](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=d7292959201c76e8) | user-management-service · `render_partial.action_view` | 43.939 | 43.939 | 0.000 |
| `organization-warm` / [bf558cdef6a23d5a](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=bf558cdef6a23d5a) | group-service · `POST /group_users/search` | 46.446 | 30.164 | 0.000 |
| `organization-warm` / [dbca1745990b88c2](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=dbca1745990b88c2) | user-management-service · `connect` | 22.984 | 22.984 | 0.000 |
| `organization-warm` / [3ad80d6f6157a73d](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=3ad80d6f6157a73d) | group-service · `POST /group_users/search` | 37.432 | 22.683 | 0.000 |
| `organization-warm` / [0fcc05cfa5fef747](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=0fcc05cfa5fef747) | group-service · `POST /group_users/search` | 32.526 | 18.190 | 0.000 |
| `organization-warm` / [45cc9c8ba5d31cbf](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=organization-warm&span=45cc9c8ba5d31cbf) | account-service · `POST /accounts/search` | 19.768 | 10.944 | 0.000 |
| `graphql-cold` / [0e47e375c7f9b260](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-cold&span=0e47e375c7f9b260) | user-management-service · `graphql.execute_multiplex` | 338.658 | 337.265 | 279.038 |
| `graphql-cold` / [90dcf8c83b2d0483](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-cold&span=90dcf8c83b2d0483) | authorization-service · `connect` | 35.052 | 35.052 | 0.000 |
| `graphql-cold` / [43b0c77d27df07f4](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-cold&span=43b0c77d27df07f4) | user-management-service · `connect` | 21.593 | 21.593 | 0.000 |
| `graphql-cold` / [5007da6f512b4cb5](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-cold&span=5007da6f512b4cb5) | account-service · `POST /accounts_with_parents` | 24.966 | 12.559 | 0.000 |
| `graphql-warm` / [d1d2bc21c76e043b](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-warm&span=d1d2bc21c76e043b) | user-management-service · `graphql.execute_multiplex` | 216.042 | 212.570 | 197.160 |
| `graphql-warm` / [67302aa05a05899c](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-warm&span=67302aa05a05899c) | user-management-service · `connect` | 50.912 | 50.912 | 0.000 |
| `graphql-warm` / [74d5a84cfb5d43c0](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-warm&span=74d5a84cfb5d43c0) | user-service · `POST /users/search` | 25.136 | 16.300 | 0.000 |
| `graphql-warm` / [d912ae45bb17239d](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-warm&span=d912ae45bb17239d) | user-management-service · `connect` | 14.189 | 14.189 | 0.000 |
| `graphql-msp` / [f5dff698f2bea008](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=graphql-msp&span=f5dff698f2bea008) | user-management-service · `graphql.execute_multiplex` | 198.695 | 198.348 | 60.057 |
| `authorization-collection-can` / [619efe7faabcc96f](http://localhost:4175/articles/series/IAM-System-Demo/graphql-auth-explosion-trace-browser?trace=authorization-collection-can&span=619efe7faabcc96f) | account-service · `POST /accounts_with_parents` | 51.855 | 35.372 | 0.000 |

GraphQL's three `graphql.execute_multiplex` spans each have only one direct child. Much of their interval overlaps source work recorded elsewhere under the request root. This is a parent-context audit target, rather than evidence that GraphQL did no work during 98–100% of execution.

## Reproduce the audit and close the instrumentation task

The replay audit is a standard-library script and reads only the small displayed payloads plus their archive-status sidecars:

```sh
python3 scripts/audit_displayed_traces.py \
  --site-root ~/Documents/whirred-io \
  --output-dir reports/summary
```

- [Full gap audit, every pair and flagged span](summary/displayed-trace-gap-audit-2026-09-10.json)
- [Browser bar geometry audit](summary/displayed-trace-renderer-audit-2026-09-10.json)
- Website selection: `docs/public/traces/iam/manifest.json` in `whirred-io`; URLs in this note require that site's local server on 4175.

Re-run the exact successful wide case with instrumentation enabled, select the same nested route and caller context, and report old/new trace IDs, request cardinalities, phase timings, and instrumentation overhead. Reproduce the warm GraphQL gap separately with its original fixture/cache settings. Accept when the client/server boundary is accounted for by observed phase intervals, endpoint materialization/serialization is visible where needed, and GraphQL parent-context behavior is either corrected or explicitly documented. Do not require the original 37.479 ms gap to recur identically, and do not alter archived span times, fabricate children, or relabel unexplained elapsed time as CPU/network time.
