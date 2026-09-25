# Authorization audit corrections follow-up — 2026-09-24

## Baseline and scope

All three reported defects remained in the current checkout:

- `authorization-service` allowed an empty Account target set through `/can` by vacuous `all?` success.
- `organization-service` materialized and authorized the complete MSP managed-account relation before paginating it in Ruby.
- `OrganizationAccount` had only the organization-scoped read declaration, so it did not implement the single per-row organization-or-account policy across every lookup form.

The changes were kept as three reviewable commits. Existing unrelated work was left untouched.

## Corrections

### A. Empty Account `/can`

`authorization-service/app/controllers/can_controller.rb` now requires a nonempty normalized Account target set as well as authorization of every target. The existing pending request regression was promoted. Malformed IDs, missing context, and nonempty allow/deny behavior retain their existing paths.

### B. Requested MSP page only

`organization-service/app/controllers/internal/msp_managed_organizations_controller.rb` retains provider relationship validation and the actor's provider `account.read` check. Under that boundary it counts the full distinct managed-account relation in SQL, applies stable offset/limit pagination in SQL, materializes only the requested page, and submits only page Account IDs for `account.read`. Response fields and continuation semantics are unchanged. The separate `/internal/...` route remains `IAM_SYSTEM`-only, while `mspUserManagement` continues to forward the real actor to the actor-authorized route.

Request coverage proves a seven-row relation reports seven while materializing and authorizing one row for a one-row page; later, empty, terminal, and out-of-range pages retain their count/cursor behavior; unauthorized providers and page accounts deny; and an unreadable off-page account neither appears in authorization input nor denies the page. GraphQL caller coverage remains green.

### C. Correlated `OrganizationAccount` relationship policy

`OrganizationAccount` now declares the relationship policy once through the shared `authorized-resource` abstraction:

```text
organization.read.accounts(row.organization_id) OR account.read(row.account_id)
```

The OR is evaluated per row and every returned row must pass. Organization counts and hierarchy organization-context retrieval keep their narrower existing endpoint requirements rather than inheriting the relationship-row OR.

Capabilities mode derives correlated decisions from its existing batched capability responses. Precise mode uses the new narrow `POST /internal/decisions` contract for only the two required permission/scope pairs. It requires a real actor, validates a bounded nonempty request, evaluates only explicitly requested targets with the existing authorization evaluator, and returns fully correlated booleans. The shared client fails closed on missing, duplicate, malformed, or uncorrelated decisions. Public `/can` remains all-or-nothing and unchanged except for correction A.

The persisted fixture uses deliberately distinct organization-only, account-only, and mixed actors. It proves row lookup, account filtering, and combined filtering; per-row mixed A+B allow and A+B+C denial; permission non-interchangeability; unrelated-grant isolation; and cold/warm cache identity by actor, permission, scope type, and target.

## Architectural preservation

No hierarchy implementation file changed. Cache misses still obtain organization membership scope from organization-service before account-service runs its existing batched recursive SQL CTE. Recursive edges remain constrained to each root's correlated organization scope. The existing multi-root, cycle, depth, missing-record, and boundary behavior was not redesigned.

Service ownership also remains unchanged: organization-service owns organization membership and the relationship-row policy; account-service owns physical `parent_account_id` links and the recursive CTE; authorization-service owns grant evaluation and decisions. Actor context is forwarded unchanged. `IAM_SYSTEM` and `IAM_SYSTEM_AUTH` retain distinct restricted uses. Both authorization modes remain batched, and precise mode does not enumerate full capabilities.

## Validation performed

- `authorization-service`: 65 RSpec examples, 0 failures.
- `organization-service`: 42 RSpec examples, 0 failures.
- `gems/authorized-resource`: 28 RSpec examples, 0 failures.
- Account hierarchy request regression: 9 RSpec examples, 0 failures, including one set-based CTE for multiple roots.
- MSP GraphQL path: 2 runs, 4 assertions, 0 failures/errors/skips.
- Persisted boundary fixture, `AUTHORIZATION_CHECK_MODE=can`, Redis disabled, batched retrieval: 24 examples, 0 failures; live correctness gate passed 10 checks; individual and batched hierarchy identity checks passed.
- Persisted boundary fixture, `AUTHORIZATION_CHECK_MODE=capabilities`, Redis enabled, batched retrieval: 24 examples, 0 failures; live correctness gate passed 10 checks; individual and batched hierarchy identity checks passed.

## Deferred work and limits

The withdrawn S-2 hierarchy membership/fact-exchange optimization and S-3 grant-group optimization were not implemented or recreated. Organization membership ID exchange for hierarchy computation remains as designed. No benchmark matrix, large-data reseed, deployment, article update, invalidation redesign, or full publication gate was run. The live correctness gate itself documents that it samples seed identities; the focused cross-service regressions above provide the additional evidence for these corrections.
