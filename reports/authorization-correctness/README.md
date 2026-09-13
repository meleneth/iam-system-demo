# Authorization correctness investigation — 2026-09-13

**Publication blocked.** At investigation completion, the repairs were implemented in the working tree and the original benchmark stack failed the new live correctness gate. Following subsequent user authorization, the local prod stack was repaired in place and passed all 26 live gate checks; see the [rollout record](rollout-20260913/README.md). Dev was subsequently deferred by the user. Historical timing/trace files have been preserved. A historical success or attractive timing is not evidence that the repaired program enforces authorization. The investigation observations below describe the pre-rollout state unless otherwise noted.

## Policy and the initially cited query

The requesting actor, permission, scope type and target must all survive the request. Account grants inherit down the actual parent chain, not upward, sideways, or across unrelated roots. Organization capability results are direct Organization grants. `organization.read.accounts` (plus the documented legacy alias) authorizes membership enumeration; reading an account alone does not authorize enumeration of its organization. Accounts use `account.read`; users, groups, group memberships and their counts use `account.users.read` under the existing repository contract.

MSP ownership is an additional **explicit organization relationship**, not a global role. Per the user's clarification and TODO.md's established cohort policy, valid client access requires (1) `msp.admin.users` on the specific MSP organization, (2) the requested non-MSP operational permission on its cohort account, (3) organization-service proof that this cohort belongs to that MSP and that the target's client organization is linked to that exact pair, and (4) a valid target account hierarchy. Two client organizations under the same MSP can legitimately be related. Combining an MSP grant for A with operational grants for B does not create authority over either set of clients. No old `msp_account_id -> managed_account_id` projection was restored. Account capability arrays still exclude `msp.*`.

AGENTS.md/FINAL_ARCHITECTURE.md reject the obsolete account-to-account ownership model; TODO.md and later architecture sections describe organization relationships with operational cohorts. Initially these appeared contradictory. The user clarified that organizations owned by the same MSP are related. Tests retain those legitimate allows and enforce the exact relationship; they do not implement “deny all MSP clients.” Two provisional denial expectations in `original-extended.txt` predate that clarification and are **not counted as defects**.

The cited SQL appears in `Authorization::Capabilities` in both account-capability and account-permission paths. It enumerates the actor's candidate MSP Organization scope IDs. The subsequent account-grant query retains the actor and operational permission; `/internal/auth/account_contexts` validates the candidate MSP organization/cohort against the target's owning organization. An empty candidate set returns no reflected authority. The fact that the target is absent from that first SQL is not, by itself, a missing authorization boundary.

The actual cited actor `f9684f2b-2fd0-5dd0-b783-9cb238dbc396` is the deep-chain root admin. Read-only inspection of the existing stack found **zero MSP grants** for it. Its account grants (`account.read`, `account.users.read`, `account.users.create`, `group.create`) are scoped to `b4e0a16b-eb9d-597d-bab0-56c2b3e041f4`; its three Organization grants are scoped to `5a5d4169-e947-5435-9de8-5d7248e84d3e`. The leaf in the documented request belongs to that root's 25-account chain. That particular MSP lookup does not explain a global allow.

## Confirmed failures and implemented repairs

| Failure | Original proof | Repair |
|---|---|---|
| Organization batch used `exists?` over all supplied IDs: one grant approved every organization | `original-organization-batch.txt`: expected 403, got 200. `original-cross-service.txt`: an MSP A actor receives both A and B membership rows. Also reproduced against existing benchmark stack. | `authorization-service/app/controllers/can_controller.rb` requires the requested permission on **every** requested Organization ID; explicit input context is required. |
| Membership `show` returned an organization/account mapping without authorization | `original-cross-service.txt`: MSP A reads MSP B's membership row, HTTP 200 | `organization-service/app/controllers/organization_accounts_controller.rb` checks the same explicit Organization-membership or Account-read authority used by collection paths, including missing actors. |
| Account context lookup widened a child-only grant to all organization account IDs | `original-cross-service.txt`: child reader gets root, sibling and independent-root IDs | Organization enumeration requires Organization membership-read permission before reading cached lists. The single-account variant also checks Organization-read permission before returning the Organization object. |
| Hierarchy endpoints authorized only the target, then returned unauthorized ancestors and names | `original-cross-service.txt`: child reader gets the parent object | `account-service/app/controllers/accounts_controller.rb` checks every returned hierarchy record in addition to requested targets. Internal hierarchy fact retrieval remains an intentional `IAM_SYSTEM` call; it is not returned to the actor without checking. |
| GraphQL root fields overwrote a shared `context[:as]` | `original-extended.txt`: the `denied` field returns users using another root field's user-read grant | UMS query/resolver identity and preloaded user context now use GraphQL field-subtree scoping. Tests exercise both field orders, exact allowed users, and the denied error path. |
| MSP page returned target IDs/counts from a privileged enumeration on MSP role alone | `partial-repair.txt`: role-only actor receives a page despite lacking operational grants | New actor-scoped organization-service page endpoint checks exact MSP Organization permission and all collection target Account-read permissions before disclosing IDs, total count or continuation. UMS carries the real actor; the narrow internal endpoint remains internal. |
| Frontdoor discovered and impersonated the selected organization's administrator | `original-frontdoor-rerun.txt`: supplied MSP B actor gets MSP A's page, HTTP 200 | Frontdoor detail keeps the supplied actor for all owning-service requests. Unrestricted random discovery and hardcoded system-debug routes were removed. Legacy account views also propagate the actor to every downstream model. |

Denial paths that previously raised unhandled exceptions now return 403 without target/principal details in their error body. An unrelated account's original 500 is recorded as a fail-closed error, **not** as an unauthorized allow. Large Organization `/can` requests use the existing POST contract to retain their complete target sets.

The fixture is `test/integration/authorization_fixture.rb`: two unrelated MSPs; two client organizations under A and one under B; a root/child/grandchild/sibling and independent branch; explicit principals with role-only, membership-only, wrong-permission, wrong-scope and mismatched-MSP/cohort grants. It is installed through each owning service's Rails runner into separate test databases. HTTP RSpec exercises actual persisted objects, owning services and authorization code. No authorization decision is mocked in this proof.

## Data and background projection

Read-only inspection found three duplicate organization-membership pairs (six original rows), **zero accounts in multiple organizations**, three native MSP-admin grants, and no obsolete MSP/reflected authorization tables. `existing-duplicate-memberships.txt` preserves all six rows. None of these duplicate account IDs is in the named MSP fixture's deterministic client-account set. No blanket or cross-MSP grant contamination was demonstrated; native seeding projects grants to the event's actual Organization and Account.

`20260913000000_enforce_single_account_organization.rb` repairs existing duplicate projections, archives their complete original rows, then makes `organization_accounts.account_id` unique. It refuses ambiguous ownership instead of guessing a tenant. The owning model and queue worker enforce/idempotently create that membership. Migration specs check exact preservation of the original rows and refusal to repair conflicting owners. The migration was applied only to the isolated test database. **The existing benchmark stack's three duplicate pairs remain pending this migration; no deployment or live-data deletion was performed.** This is not a claim that future grant creation alone repairs previously contaminated authority.

## Verification and evidence index

Run `scripts/test_authorization_boundaries.sh` through the normal repository environment. It starts only the test databases and temporary test-service processes, seeds only its dedicated fixture IDs, clears only fixture-keyed test Redis data, then runs the HTTP RSpec proof. It runs the live benchmark gate and small hierarchy timing checks only after RSpec passes. It stops the temporary web processes afterward. It must not run concurrently with service specs that prepare the same test schemas.

Final matrix artifacts are `final-can-false-serial.txt`, `final-can-true-batched.txt`, `final-capabilities-false-serial.txt`, and `final-capabilities-redis.txt`. Each contains the exact RSpec results, the live gate's individual decisions, and identities/parent links from the small individual-vs-batch hierarchy rerun. Redis-enabled runs include cold and repeated warm calls, with an authorized principal warming data before unauthorized principals request it. These are small correctness-verified samples, **not replacement article-scale timings**.

The suite covers actual allows and denials for direct/inherited Account permissions; ancestors/siblings/descendants/unrelated roots; MSP ownership across two client organizations; mixed grants across MSPs; Organization and Account batches; list/search/show; group membership; counts including authorized zeroes; MSP pagination including totals; GraphQL mixed actors and nested data; HTML partitions; missing/empty context; and the old frontdoor bypass. Existing and added service RSpec also check malformed/cyclic/deep/missing/duplicate hierarchy responses, randomized tree oracles, Redis failure, dependency failure, scope/permission cache keys, grant revocation and relationship removal. Verifying doubles are used for remote dependency failure injection, not for authorization decisions.

Final recorded results:

| Check | Result |
|---|---|
| Cross-service RSpec, `/can`, Redis off, serial | 15 examples, 0 failures |
| Cross-service RSpec, `/can`, Redis on, batched | 15 examples, 0 failures |
| Cross-service RSpec, capabilities, Redis off, serial | 15 examples, 0 failures |
| Cross-service RSpec, capabilities, Redis on, batched | 15 examples, 0 failures |
| Live gate on repaired test stack | 10 independently specified checks passed in each configuration |
| Small hierarchy reruns | Individual and batch exact-identity/parent-link checks passed in each configuration |
| Authorization-service RSpec | 38 examples, 0 failures |
| Organization-service RSpec, including data migration | 31 examples, 0 failures |
| Account-service RSpec | 30 examples, 0 failures, 10 pre-existing scaffold placeholders pending |
| User-service / group-service RSpec | 17 / 22 examples, 0 failures |
| UMS existing tests | 27 tests, 89 assertions, 0 failures/errors |
| Repository harness/configuration tests | 38 tests, 240 assertions, 0 failures/errors |
| Patch whitespace and shell syntax | Passed |

The one-shot hierarchy durations are retained in the matrix logs, along with exact returned identities. They were taken after the gate and are not statistically useful speedup estimates. Service suite outputs are named `*-service-specs.txt`; UMS output is `user-management-tests.txt`.

Earlier `original-*` and `partial-repair*` artifacts retain failures. Files mentioning import, tracing setup, schema preparation, or missing benchmark `csv` dependencies are harness/setup failures, not authorization proof. `existing-stack-gate.json` was sandbox-blocked; use `existing-stack-gate-network.json` for the actual live-stack observations. `root-checks.txt` records repository harness/configuration checks.

## Consistency contract and audit limits

Final capability/permission caches are keyed by actor, scope type, target and (for `/can`) permission, with a non-sliding 300-second TTL. A grant revocation or MSP relationship removal can remain visible through an existing cached answer for that TTL; Redis-disabled paths recompute. Tests check the allow at 299 seconds and denial/reduction at 300 seconds, including preservation of unrelated direct grants. There is no revocation API or event-driven invalidation implementation. The create worker does not update existing account parents. No immediate-revocation claim is made.

External SQL edits to account parents or organization membership are outside the supported create-only workflow. Layered 300-second organization-membership, hierarchy and authorization caches can extend the observation delay beyond a single TTL (up to three sequential TTL windows). Such administrative edits require coordinated invalidation or quiescence before measuring; “every cache expires after five minutes” must not be represented as a universal five-minute end-to-end consistency guarantee. Implementing a general mutation/invalidation protocol remains separate work.

Inspected consumers: `/can` and capability endpoints; REST account/user/group/membership reads, searches and counts; both account-parent endpoints and their recursive SQL; organization enumeration and counts; MSP fact/page endpoints; UMS GraphQL roots, dataloaders and nested fields; HTML account/organization/frontdoor routes; queue seed/projection workers; service cache population; fixture generation; both benchmark drivers and article collection configuration. Service GraphQL schemas outside UMS are generated stubs rather than a separate implemented resource-read API. Unrouted scaffold mutation methods are not a supported mutation API. The unused generic cache helper is not part of the observed permission path.

This demo still trusts caller-supplied identity and its explicit internal identities. Authentication, signed service requests, and a production write/revocation system are absent by design; this investigation is not a certification of production security. No new actor-to-system bypass was introduced.

## Publication and benchmark disposition

- The existing stack demonstrably returns 200 for each tested cross-MSP mixed Organization list. Its unrelated-account denials return 500. The new gate rejects that stack before measurement; both benchmark drivers now require the gate and refuse overwriting existing timings.
- Historical raw results, trace files and summary JSON are preserved. Their measured durations remain historical observations of the old program. Claims that those numbers establish correct authorization/isolation are withdrawn/unverified. The added hierarchy, enumeration and actor checks change work performed, so old performance numbers are not measurements of this repair.
- Manifest analysis establishes that the deep/wide/dense/sparse benchmark root principals have parent-chain reach over 25/25, 251/251, 1/1 and 401/401 accounts respectively. The MSP measured admins have both their explicit MSP and operational grants. No unrelated-target allow was demonstrated in those **specific positive workload selections**; that does not validate the former primitives or their performance claims.
- The `branching_tree` fixture has four roots. Its first-root admin reaches only 85/340 accounts and cannot read the configured last leaf. The experimental account-page request is a denial case, not a successful all-tree workload. The gate now explicitly expects that denial; do not add universal grants to make the benchmark pass.
- Full article reruns remain blocked: use the repaired code and repaired data in a fresh isolated benchmark environment, pass these boundaries and the live gate, validate full returned identities, then rerun the matrix's hierarchy, Organization and MSP walks at all affected sizes/cache modes. In particular MSP 10k/50k/100k timings need a complete rerun because page/count authorization now proves all targets. Existing hardware/configuration/SQL-shape observations may remain descriptive history; no repaired-program speedup is claimed from them.
- No publication or deployment was performed. The small final hierarchy samples establish that measurement can follow successful authorization gates; they do not unblock the article-scale claims.
