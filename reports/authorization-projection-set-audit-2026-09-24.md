# Authorization projection and set audit — 2026-09-24

## Result and review boundary

Revision reviewed: `dfc39d54449c7031d9a10337821b119f9156b72c` (`main`, one commit ahead of `origin/main`). The worktree was clean before this audit. The audit adds only focused/pending regression evidence, one scaling diagnostic, and this report; production behavior is unchanged.

This review used `AGENTS.md`, `CORE_INVARIANTS.md`, `FINAL_ARCHITECTURE.md`, `reports/group-grants-implementation.md`, `reports/core-invariant-fixes.md`, and `reports/authorized-resource-boundary-correction-2026-09-21.md`. The 2026-09-13 audit's special-MSP-role policy is historical and conflicts with the current contract; it was not used as an oracle.

Publication remains blocked. Two correctness defects and three material scaling problems are confirmed. No projection-based unauthorized record filtering was found: owning services reject a mixed collection, and `AuthorizedResource` only transports the actor context.

## Policy mapping actually required

| Protected object/response | Authoritative read decision |
| --- | --- |
| `Account` row | `account.read` on that account, including physical/provider inheritance. `IAM_SYSTEM` is intentional for internal hierarchy facts. |
| `account_with_parents` | `account.read` on the requested target **and every returned account**. It does not grant unrelated operations on ancestors. Internal authorization-service fact retrieval uses `IAM_SYSTEM`; actor-facing retrieval does not. |
| `User` row/count | `account.users.read` on its owning/requested account. |
| `Group` row | One Group-object policy: exact `group.read`, or `account.users.read` on the owning account. Authorization-service coherently maps both sources into the Group capability decision (`capabilities.rb:48-76`, `88-113`). |
| `GroupUser` relationship | Same Group-object decision as its group. The membership row does not authorize itself. |
| `Organization` row | Direct `organization.read` on that organization. |
| Organization account count/context enumeration | `organization.read.accounts` on the organization; account-context endpoints additionally require `account.read` on every requested account. |
| `OrganizationAccount` relationship row | One relationship-object decision with alternatives: `organization.read.accounts` on its organization **or** `account.read` on its account. Current code implements only the first alternative; finding ID-1. |
| `MspManagedOrganization` / actor page | `account.read` on the provider relationship target and every disclosed managed account. Provider affiliation alone is not authority. Internal page is `IAM_SYSTEM` only. |
| `CapabilityGrant` | IAM-only resource access. A real actor is authorized only through an explicit membership in the exact grant group and a matching permission/scope path. |
| Internal membership/group/provider facts | `IAM_SYSTEM_AUTH` only. These endpoints return relationship facts, not permission decisions. |

Membership has two correlations, both required by the current contract: `(user_id, group_id)` must be an explicit row, and that same `group_id` must occur on the matching grant row. The grant's Account scope, not the group's owning account, establishes target account context. No reviewed governing source requires a grant group's owner account to equal its grant scope; adding that restriction would be a new policy decision.

Empty `/can` target sets are unauthorized, per the user clarification during this audit. Organization and Group already implement that rule. Account does not.

## Findings by impact

### Unauthorized authorization result

#### UA-1 — empty Account `/can` returns allow

- Code: `authorization-service/app/controllers/can_controller.rb:27-32`; executable regression: `authorization-service/spec/requests/can_spec.rb:98`.
- Rule: an empty authorization question is not authorized.
- Reproduction: `POST /can/Account/account.users.read` with `{"scope_id":[]}` and a real actor.
- Expected/actual: 403 / 200.
- Cause: `requested_account_ids.all?` is vacuously true; unlike Organization and Group, Account has no `any?` guard.
- Smallest proposed fix: use `requested_account_ids.any? && requested_account_ids.all? { ... }`, and retain the pending regression as a normal passing regression.
- Exposure: this is a false allow from the authorization primitive, although the request contains no object ID and this audit did not demonstrate disclosure of a record from it.

### Incorrect denial

#### ID-1 — the single-policy change discarded legitimate Account authority for relationship rows

- Code: `organization-service/app/models/organization_account.rb:5-7`; real fixture: `test/integration/authorization_boundary_spec.rb:38-48`; pending focused regression: `organization-service/spec/requests/organization_accounts_spec.rb:112-135`.
- Rule: one authoritative relationship-object policy must coherently evaluate its two legitimate authority sources. Enforcing one declaration does not permit deleting one source.
- Fixture/request: `child_reader` has `account.read` on `child_a` and no `organization.read.accounts` on `client_a`; request the exact `OrganizationAccount` row by `account_id`, combined filters, and row ID.
- Expected/actual: all three return the same row with 200 / the first filtered lookup returns 403.
- Cause: commit `dfc39d5` removed the second model declaration to enforce one policy, but did not replace the competing declarations with a single composite relationship policy. The new unit expectation was changed to match that implementation, while the independent persisted fixture and `reports/core-invariant-fixes.md` retain the governing result.
- Smallest proposed fix: add one `OrganizationAccount` policy resolver/evaluator owned by organization-service whose per-row predicate is `(organization.read.accounts on organization_id) OR (account.read on account_id)`. Keep collection quantification outside the alternatives: every row must satisfy at least one branch. Do not restore multiple model declarations and do not let a grant for one row authorize another row.

### Scaling problems (correctness preserved)

#### S-1 — an authorized MSP page materializes and authorizes the whole managed set before slicing

- Code: `organization-service/app/controllers/internal/msp_managed_organizations_controller.rb:39-45`; diagnostic: `organization-service/spec/requests/msp_managed_organizations_spec.rb` (“one-row page”).
- Controlled result: seven managed relationships, `limit=1`, response size one; the authorization batch and in-memory relation both contain seven rows and `total_count=7`.
- Bound: all managed accounts for the provider, not page size. Every subsequent page repeats the whole load and authorization.
- Cause: `account_scope.to_a`, `authorized_read`, and `.size` precede `slice(offset, limit)`.
- Smallest proposed fix: separate page rows and count at the owning service, while preserving the policy that count disclosure is allowed only after the necessary authority is proven. This likely needs a narrow set-oriented authorization-service primitive or a clarified count policy; merely moving `slice` before authorization would be incorrect.

#### S-2 — a bounded hierarchy miss transports/materializes the target's whole organization account set

- Code: `account-service/app/controllers/accounts_controller.rb:135-145`, `185-224`; producer/cache: `organization-service/app/controllers/organization_accounts_controller.rb:102-178`.
- Bound: sum of the complete account memberships of every distinct organization containing a missed target, rather than requested targets × hierarchy depth. One hierarchy target in a very wide organization transports every organization account ID as `seed_ids` even though the recursive result is capped at 100 ancestors.
- Correctness: `root_id` remains in every CTE tuple; recursion is constrained by that root's `seed_ids`, cycle path, and depth, and results are grouped back by `root_id`. No cross-target borrowing was found.
- Smallest proposed fix: introduce an owning-service fact contract that validates only the candidate physical parent chain (or returns a bounded chain-membership proof), rather than returning the whole organization membership set. Do not remove the organization boundary check.

#### S-3 — narrow `/can` enumerates the actor's total membership universe

- Code: `authorization-service/lib/authorization/capabilities.rb:156-180`; producer: `group-service/app/controllers/internal/auth/contexts_controller.rb:8-20`.
- Bound: all explicit groups for the actor, independent of requested target count, permission, hierarchy depth, or matching grants. The tuple projection itself is correct, but its response and the subsequent SQL `group_id IN (...)` grow with unrelated memberships.
- Correctness: the membership endpoint predicates `user_id`, joins real groups, and returns `(group_id,user_id)` tuples; the client discards `user_id` only because it is fixed by the request. The same `group_id` remains on the grant query, so unrelated membership and grant facts are not recombined.
- Smallest proposed fix: first project candidate grant group IDs using the requested permission and correlated target scope paths, then ask group-service whether this actor belongs to only those group IDs. Preserve one batched membership call and the exact group-to-grant correlation.

Full-capability account retrieval is intentionally broader than `/can`, but it also evaluates targets serially in `CapabilitiesController#capability_map`; that is a requested-target scaling cost, not whole-dataset enumeration. Group full-capability retrieval is set-oriented.

## Projection and set inventory

| Producer/path and shape | What set membership establishes; retained/discarded facts | Bound and assessment |
| --- | --- | --- |
| `AuthorizedModel::RelationProtection` (`authorized_model.rb:23-40`) wraps `pluck`, `pick`, `ids`, calculations and `exists?` | A projection by a real actor establishes nothing unless an outer `authorized_read` supplied explicit targets. IAM-only aggregates are allowed. | Query result size. Correct boundary: raw projection cannot bypass policy merely by avoiding model instantiation. |
| `AuthorizedModel.authorize_records!` (`authorized_model.rb:109-146`) maps record → one policy target, deduplicates targets, then requires every record target's capability | Target membership means that exact record's authoritative policy target is allowed. Record correlation remains in `targets_by_record`; missing target is configuration failure. | Distinct targets in materialized result. Correct for current single-target policies; OrganizationAccount needs one composite policy (ID-1). |
| Shared authorization client (`authorization_client.rb:34-60`) groups by scope type/capability, deduplicates, chunks, and merges maps | In capability mode, each returned ID carries its own capabilities. In `/can`, a successful chunk establishes every ID in that exact all-or-nothing question; a denied chunk contributes none, causing the owning-service whole collection to deny. | Requested distinct targets, chunk ≤ `IAM_DEMO_BATCH_SIZE`. Duplicates/order safe. A later denied chunk cannot become partial success. |
| Organization grant projection (`capabilities.rb:19-28`) `pluck(:permission)` | Applicable permissions for one fixed actor group set and one exact organization. Scope type/ID and groups are fixed by SQL predicates. | Matching grants for one organization. Correct. |
| Account full capabilities (`capabilities.rb:32-39`) `pluck(:permission)` | Permissions applicable to one fixed target's already-correlated physical/provider scope path. Scope IDs may be discarded because only one target is being evaluated. | Path scopes × actor groups × matching grants. Correct, but per-target controller loop. |
| Batched Account `/can` (`capabilities.rb:122-175`) flattened candidate scopes + `pluck(:scope_id)` + per-target `any?` | A projected scope ID establishes a matching grant only. Authorization is re-correlated by testing each target's own hierarchy/provider list. Permission, scope type, actor groups are SQL predicates. | Requested targets × max path 100; matching grants. Correct lost-correlation defense. |
| Account full-capability batch helper (`capabilities.rb:306-322`) `pluck(:scope_id,:permission)` | Tuple preserves grant scope/permission; each target reads only tuples on its own scope path. | Candidate path scopes and matching grants. Correct. |
| Group direct grants (`capabilities.rb:48-76`, `88-113`) `pluck(:scope_id,:permission)` / `pluck(:scope_id)` | Direct tuple/set applies only to exact group ID; owning-account capabilities are separately keyed by that group's `account_id`, then alternatives are unioned per group. Independent legitimate grants are allowed; unrelated rows cannot recombine. | Requested groups + distinct owner accounts + actor memberships. Correct. |
| Group auth facts (`contexts_controller.rb:8-29`) `(group_id,user_id)` and `(id,account_id)` | Explicit membership and authoritative group ownership. Joins exclude dangling membership groups. Fixed requested user permits downstream omission of `user_id`; ownership tuple remains correlated. | All actor memberships for user lookup (S-3), or requested group IDs. Correct result, broad user lookup. |
| Provider facts (`account_contexts_controller.rb:14-26`) `(target account, provider account, provider org, client org)` | A candidate virtual edge proved by target ownership, managed-client relation, and provider membership. Downstream keeps target→provider; discarded org IDs were predicates for that edge. Uniqueness constraints prevent competing owners/clients; malformed duplicate responses raise. | Requested valid frontier each provider round, max 100. Correct correlation and direction. |
| Physical hierarchy CTE (`accounts_controller.rb:200-233`) `(root_id,organization_id,id,parent_id,name,level,path)` | Each row is an ancestor on that root's physical parent chain and inside the root's organization membership set. `root_id` survives grouping. | Returned rows ≤ roots × 100, but input seed arrays are whole organizations (S-2). Correct edge direction/correlation. |
| Authorization scope graph (`capabilities.rb:367-409`) target→physical chain and target→provider edge maps, per-target visited set, `uniq` | Scope membership is an applicable grant scope for that exact target. Cycles/missing hierarchy clear the target path; over-depth errors fail closed. | Targets × up to 100 virtual rounds/path nodes. Correct. |
| Organization account caches (`organization_accounts_controller.rb:102-178`) organization→account ID array and account→organization map | Cached value is authoritative membership for exactly one organization; cache key contains organization ID. Unique account ownership makes `index_by` safe. | Whole organization. Correct identity/coverage, materialization contributes to S-2. |
| Account hierarchy cache (`accounts_controller.rb:97-161`) target account→ordered row array | Cache hit answers exactly one target; zip is positional over the same requested ID list. Returned authorization is performed after cache retrieval for actor paths. | Requested IDs and ≤100 returned rows per key. Correct; cache stores owner-derived data, not actor authority. |
| Final authorization caches (`capabilities.rb:188-304`, `416-423`) | Capability key includes actor/scope type/target; `/can` key includes actor/type/permission/target. Cached booleans are zipped to the same canonical distinct targets. | Requested targets. Correct cold/warm separation; TTL staleness remains documented/out of scope. |
| Counts (`users_counts_controller.rb`, `groups_counts_controller.rb`, organization count controller) | Explicit requested synthetic targets are authorized before grouped count projection; zero-fill happens only after all requested scopes pass. | Requested accounts/one organization + matching rows. Correct; empty count requests return empty data without calling `/can`, not an authorization allow. |
| MSP page (`msp_managed_organizations_controller.rb:26-53`) projection/slice/count | Provider tuple is checked; membership in the materialized relationship set means a managed account and every member is account-authorized before any IDs/count are disclosed. | Whole provider managed set per page (S-1). Correct result, unbounded page work. |
| UMS chunk aggregation and maps (`AccountById`, organization partition, GraphQL sources) | Owning services have already authorized returned records. Exact requested-vs-returned ID comparisons reject missing, extra, or duplicate account rows; `index_by` is then safe. Membership/group joins use exact IDs. | Requested/page objects and their returned children. Correct transport-only consumption; no local reauthorization. |
| `Account.with_parents_batch_ordered` (`gems/account-resource/lib/account_resource.rb:42-62`) | Target ID is taken from each chain's last row; duplicates/missing/unexpected targets map to an empty chain rather than being borrowed. Input duplicates are restored in requested order. | Requested unique targets × returned depth. Correct for authorization-service, which treats empty as denial. |

No reviewed authorization decision relies on equal counts as proof of equal membership. Exact consumer comparisons sort full ID arrays, so duplicates change cardinality and fail. Hash overwrites are protected by primary/unique constraints or explicit duplicate detection. Database/dependency errors propagate; Redis errors fall back to authoritative evaluation. Missing hierarchy and malformed IDs deny rather than broaden authority.

## Independent fixture evidence

The persisted fixture in `test/integration/authorization_fixture.rb` is small and hand-addressable: two unrelated providers, two client organizations under provider A and one under B, physical root/child/leaf/sibling branches, explicit provider relationships, groups, memberships, correct/wrong permissions, correct/wrong scopes, mixed grants, exact-group grants, members and nonmembers. Expected IDs are deterministic UUIDv5 values derived from fixture names; expected decisions in `authorization_boundary_spec.rb` are literal and do not call production policy helpers.

The 21-example real-service run covers allowed direct/inherited/provider cases, unrelated branches/actors, mixed target rejection, cache warming across principals, hierarchy object coverage, exact group membership, missing context, and actor propagation. It produced one failure, ID-1, and 20 passes. Authorization-service unit/property coverage additionally exercises reordered inputs, duplicates, malformed/missing/duplicated hierarchy results, sibling isolation, independent grants, cache actor/permission keys, relationship failure, cycles, depth, and removal from fresh/evolved fixtures. The shared client specs exercise a denied later chunk and distinct legitimate chunks.

The fixture does not mutate production data. Revocation invalidation design and large reseeding were not exercised, as required.

## Commands and outcomes

Runtime evidence:

- `AUTHORIZATION_CHECK_MODE=can GLOBAL_IAM_DEMO_USE_REDIS=false IAM_DEMO_RETRIEVAL_MODE=batched scripts/test_authorization_boundaries.sh` — **failed as expected**, 21 examples, 1 failure: account-only relationship expected 200, got 403. This is the real persisted cross-service reproduction for ID-1.
- `./dc_test run --rm --no-deps authorization-service bundle exec rspec` — 62 examples, 0 failures, 1 pending confirmed defect (UA-1: expected 403, actual 200).
- Focused authorization-service projection suites — 47 examples, 0 failures, the same 1 pending defect.
- `./dc_test run --rm --no-deps organization-service bundle exec rspec` — 38 examples, 0 failures, 1 pending confirmed defect (ID-1).
- Focused organization relationship/provider suites — 18 examples, 0 failures, the same 1 pending defect; includes S-1 diagnostic (7 authorized/materialized targets for a one-row page).
- `./dc_test run --rm --no-deps account-service bundle exec rspec` — 55 examples, 0 failures, 10 pre-existing scaffold pendings.
- `./dc_test run --rm --no-deps group-service bundle exec rspec` — 26 examples, 0 failures.
- `./dc_test run --rm --no-deps account-service bundle exec rspec --require /gems/authorized-resource/spec/spec_helper.rb /gems/authorized-resource/spec` — 23 examples, 0 failures.

Unavailable/mis-invoked evidence:

- Host `bundle exec rspec` for `gems/authorized-resource` could not run because the host lacks locked gems. The first container invocation omitted the gem's spec helper and produced load errors; the corrected container command above passed. Neither failure is authorization evidence.
- No full benchmark matrix, large reseed, dev/prod deployment, mutation test, or publication run was performed.

Static evidence is the producer/consumer trace and inventory above. Runtime tests use verifying doubles only for dependency responses or counting diagnostic batch sizes; the cross-service defect reproduction does not stub the final authorization decision.

## Remaining limits and decisions

- A scalable S-1 fix needs a policy decision about whether `total_count` requires authority over every managed account or can be disclosed after provider authority alone. Current behavior proves every target before disclosing count; this audit does not relax it.
- The current contract does not constrain a grant group's owning account relative to the grant scope. If such a constraint is intended, it must be specified and enforced at grant creation and evaluation; it would affect every Account/Organization grant path.
- Fixed-data cache behavior was reviewed and covered by existing cold/warm tests. Immediate revocation and coordinated invalidation are explicitly out of scope, so no claim is made about mutation-time consistency.
- S-2 and S-3 have static bound proofs and focused existing fixtures, but no large-dataset byte/row benchmark was run. Claims are limited to asymptotic materialization, not measured production latency.
- Passing suites establish the listed predicates and correlations only. They are not a blanket correctness claim for mutation routes, historical benchmark artifacts, or unspecified policies.
