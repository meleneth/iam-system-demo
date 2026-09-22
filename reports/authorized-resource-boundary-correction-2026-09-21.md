# AuthorizedResource responsibility correction — 2026-09-21

`AuthorizedResource` now requires and propagates authorization context and
instruments remote operations. It does not evaluate capabilities or
re-authorize returned records. Receiving services authenticate the propagated
context and enforce their `AuthorizedModel` policies.

## Removed duplicate work

Remote resource capability declarations, policy evaluation, result filtering,
and client-side authorization spans were removed. `AuthorizedModel` retains the
policy/evaluator/client implementation used by owning services. Explicit
application calls to `/can` and `/capabilities` remain available and batching is
unchanged.

Trace counts confirm that only user-management's redundant authorization calls
were removed:

| Scenario | Before | After | Removed |
| --- | ---: | ---: | ---: |
| Wide collection `/can` | 36 | 18 | 18 |
| Organization cold | 36 | 18 | 18 |
| Organization warm | 36 | 18 | 18 |
| GraphQL cold | 13 | 7 | 6 |
| GraphQL warm | 13 | 7 | 6 |
| GraphQL MSP | 13 | 8 | 5 |

The remaining authorization requests originate in account, organization, user,
and group services, where the records and policies are owned. Hierarchy
scenarios were unchanged at 5, 2, 16, 2, and 25 requests respectively.

## Production measurements

The production stack was rebuilt through `./dc_prod` by the trace-gallery
workflow. No production reseed or full-capabilities diagnostic was run.

| Scenario | Preceding run (s) | Corrected run (s) | Change |
| --- | ---: | ---: | ---: |
| Hierarchy walk | 0.370 | 0.211 | -43.0% |
| Hierarchy CTE | 0.094 | 0.081 | -12.9% |
| Hierarchies individually | 1.044 | 0.899 | -13.9% |
| Hierarchies batch | 0.138 | 0.118 | -14.8% |
| Record `/can` | 1.301 | 1.023 | -21.4% |
| Wide collection `/can` | 6.757 | 4.073 | -39.7% |
| Organization cold | 2.391 | 2.934 | +22.7% |
| Organization warm | 2.364 | 2.160 | -8.6% |
| GraphQL cold | 0.565 | 0.410 | -27.3% |
| GraphQL warm | 0.433 | 0.285 | -34.2% |
| GraphQL MSP | 0.698 | 0.564 | -19.3% |

The one cold-cache regression is a single-run observation; request-count and
trace-structure assertions, rather than latency, establish removal of the
duplicate checks.

All 11 scenarios completed successfully. The wide collection returned the
expected 251 accounts, 5,020 users, 502 groups, and 5,271 memberships. All five
authorization gates passed 26 checks each. Reduced-trace validation confirmed
HTTP/API parentage, server-side authorization work, GraphQL documents,
application SQL, Redis pipelines, and zero user-management `/can` or
`/capabilities` client spans.

## Verification

- Shared client/server specs: 14 examples, 0 failures.
- User-management batching: 6 runs, 23 assertions, 0 failures.
- Real Puma/ActiveResource trace propagation: 1 run, 23 assertions, 0 failures.
- Cross-service authorization boundaries: 21 examples, 0 failures, plus the
  live correctness gate and individual/batched hierarchy smoke checks.
- Affected service regression suites: account 55 examples, authorization 61,
  organization 11, group 10, and user 7; all passed (10 pre-existing scaffold
  examples remain pending in account-service).
- Production gallery: 11 archived traces validated with no collection failure.

The production routes for resource creation, update, and deletion remain
intentionally disabled. Mutation context propagation and ActiveResource error
semantics are covered at the shared boundary, while `AuthorizedModel` mutation
callbacks retain server policy enforcement. No endpoint was added merely to
create an integration-test path.

Raw artifacts are archived under
`reports/raw/article-traces-20260921-authorized-resource-context-only/` and are
ignored by Git as intended.
