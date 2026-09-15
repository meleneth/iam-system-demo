# Record authorization proof

## Contract

A grant belongs to a group. An actor receives it only through an explicit membership in that group. An Account grant covers the target account, its physical descendants, and accounts covered through actual provider-account → client-organization relationships (including the provider's physical ancestors). It does not cover a sibling, an ancestor of its scope, another provider's clients, or another permission. Organization grants are exact Organization scopes. Group capability lists combine exact Group grants with Account grants covering the group's owning account.

A request containing several targets must authorize **every** target. A permission found in one target's capability list cannot authorize another target. Membership records are scoped through their owning group, not through the membership user's account.

## Checked record surfaces

| Record or response | Required authority | Test coverage |
| --- | --- | --- |
| Account | `account.read` on its account scope | Individual GET, filtered GET, search POST, mixed batches in both orders |
| Account hierarchy | `account.read` on requested accounts and every returned account | Single hierarchy and GET/POST batch; child-only grant cannot expose ancestors |
| User | `account.users.read` on its owning account | Individual GET, filtered GET, search POST, mixed batches |
| Group | `account.users.read` on its owning account OR `group.read` covering the group | Individual GET, filtered GET, search POST, exact grants, inherited grants, mixed alternatives |
| GroupUser membership | Same check on the membership's owning group | Individual GET, filtered GET, search POST, group/user filters, foreign-account member |
| Organization | Exact `organization.read` on that organization | Own/foreign organization, wrong permission/scope, missing actor |
| OrganizationAccount relationship | Exact `organization.read.accounts` on its organization OR `account.read` on its account | Row GET, filtered collection GET, each alternative, mixed collections |
| User count | `account.users.read` for every requested account | GET/POST, nonzero/zero counts, wrong grant and mixed batches |
| Group count | `account.users.read` for every requested account | GET/POST, nonzero/zero counts; exact Group grant cannot enumerate account totals |
| Organization account count | Exact `organization.read.accounts` | Exact counts, wrong organization and wrong permission |
| Compressed organization account IDs | `account.read` on input accounts AND `organization.read.accounts` on their organizations | Missing either requirement, exact returned IDs, mixed organizations |
| Organization context with embedded record | Above AND `organization.read` | Missing each constituent permission, exact organization and account IDs |
| Managed account pages | `account.read` on provider and every returned managed account | Page traversal, exact IDs/count/provider metadata, unrelated provider, wrong permission |
| Capability lists and `/can` | Actor group memberships and exact target-specific scopes | Independent expected Account, Group, Organization lists and decisions |
| Internal membership/group/organization facts | `IAM_SYSTEM_AUTH` only | Reject real actors, missing context and `IAM_SYSTEM`; validate exact owners and provider edges |
| Internal random records, managed pages, admin lookup | `IAM_SYSTEM` only | Reject real actors, missing context and `IAM_SYSTEM_AUTH` |
| GraphQL and HTML compositions | All constituent downstream checks, preserving explicit actor | Dedicated nested/compound tests plus existing boundary suite |

The runtime route inventory (`record_authorization_routes.rb`) fails on an unclassified application endpoint or a documented endpoint that disappeared. It explicitly distinguishes page shells, fixture query text, metrics, framework navigation, and generator GraphQL schemas with no implemented IAM record loader. Dormant controller CRUD methods are not routed.

## Independent fixtures and expected results

`record_authorization_fixture.rb` seeds a separate UUID namespace in **test databases only**. It creates a branched physical tree, a disconnected root in the same client organization, a second client organization of the same provider, a separate provider/client pair, and an empty account. Actors live in an unrelated account. Each grant belongs to a separately populated group; peer membership and membership without grants are exercised explicitly.

The expected target coverage is hand-written in `record_authorization_spec.rb`. It does not call the production hierarchy resolver and is not calculated by traversing the seeded parent graph. Each returned record is checked by ID, and counts/maps are checked exactly. A dedicated cross-account membership forces nested group loading to require authority beyond the user's own account.

## Reproduce

```sh
bash scripts/test_record_authorization_matrix.sh
python3 scripts/test_record_authorization_mutations.py
```

The normal matrix runs `/can` and capabilities-only modes with Redis disabled and enabled. Each example repeats its decisions without clearing caches after the first pass. Fixture cache keys are cleared before each example in Redis-enabled profiles. The suite verifies that `/can` is disabled in capabilities-only mode. The existing cross-service boundary suite also runs in each normal profile.

Evidence includes RSpec JSON results, an HTTP request/response ledger, and the classified Rails routes. Mutation runs use temporary source copies mounted only into test services. A mutation is detected only when an HTTP authorization assertion catches an unexpected `200`; startup errors, exceptions, empty suites, and unrelated failures do not qualify.

This proves the tested record-loading contracts against persisted fixtures. It is not a proof of caller authentication at an external trust boundary, or of immediate revocation during the configured cache TTL. No production seed or benchmark measurements are changed by these tests.

## Results

Final run results and mutation outcomes are recorded separately after validation completes.
