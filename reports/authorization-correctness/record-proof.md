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

The runtime inventory (`record_authorization_routes.rb`) fails on an unclassified application endpoint, a documented endpoint that disappeared, or a changed set of reachable GraphQL object/interface fields. It explicitly distinguishes page shells, fixture query text, metrics, framework navigation, and generator GraphQL schemas with no implemented IAM record loader. Dormant controller CRUD methods are not routed.

## Independent fixtures and expected results

`record_authorization_fixture.rb` seeds a separate UUID namespace in **test databases only**. It creates a branched physical tree, a disconnected root in the same client organization, a second client organization of the same provider, a separate provider/client pair, and an empty account. Actors live in an unrelated account. Each grant belongs to a separately populated group; peer membership and membership without grants are exercised explicitly.

The expected target coverage is hand-written in `record_authorization_spec.rb`. It does not call the production hierarchy resolver and is not calculated by traversing the seeded parent graph. Each returned record is checked by ID, and counts/maps are checked exactly. A dedicated cross-account membership forces nested group loading to require authority beyond the user's own account.

## Reproduce

```sh
bash scripts/prove_record_authorization.sh
```

The normal matrix runs `/can` and capabilities-only modes with Redis disabled and enabled. Each example repeats its decisions without clearing caches after the first pass. Fixture cache keys are cleared before each example in Redis-enabled profiles. The suite verifies that `/can` is disabled in capabilities-only mode. The existing cross-service boundary suite also runs in each normal profile.

Evidence includes RSpec JSON results, an HTTP request/response ledger, and the classified Rails routes. Mutation runs use temporary source copies mounted only into test services. A mutation is detected only when an HTTP authorization assertion catches an unexpected `200`; startup errors, exceptions, empty suites, and unrelated failures do not qualify.

This proves the tested record-loading contracts against persisted fixtures. It is not a proof of caller authentication at an external trust boundary, or of immediate revocation during the configured cache TTL. No production seed or benchmark measurements are changed by these tests.

## Results

Verified revision `0d45c2e`. All 364 examples passed across four normal profiles. All 39 deliberate-defect runs were detected, and each selected test passed again after restoring its source.

| Mode | Redis | Per-record examples | Existing boundary examples | HTTP requests |
| --- | --- | ---: | ---: | ---: |
| can | disabled | 70 | 21 | 5004 |
| can | enabled, cold then warm | 70 | 21 | 5004 |
| capabilities | disabled | 70 | 21 | 4420 |
| capabilities | enabled, cold then warm | 70 | 21 | 4420 |

[Machine-readable results and source hashes](record-proof-results.json). [Local raw evidence](../raw/record-authorization/) contains HTTP ledgers, classified routes, and normal/mutated/restored test reports. Raw artifacts are gitignored; their hashes are preserved in the committed summary.

The new tests exposed missing actor propagation in the GraphQL organization-count source, generic errors for denied count/context requests, and incomplete slow HTML rendering. The fixes preserve the real actor and the existing authorization rules.

### Explanatory traces

[Test Jaeger](http://localhost:11030/search?service=trace-workloads) contains allow and deny samples, each cold and warm, for both protocols. These use the dedicated proof fixtures, not production data. Full links and archive hashes are in the machine-readable results.

| Record or response | /can allow | /can deny | Capabilities allow | Capabilities deny |
| --- | --- | --- | --- | --- |
| Account | [Open](http://localhost:11030/trace/ca9646093cf6be228035faf0bc2c88c2) | [Open](http://localhost:11030/trace/5d52b5a1f2a5c24caac71f94f00cd99f) | [Open](http://localhost:11030/trace/02559ab377a8f4faec13785fbc23c4c9) | [Open](http://localhost:11030/trace/a192254b927de65ce070624f14e87a08) |
| User | [Open](http://localhost:11030/trace/38387e12a0946cb16510ce6aebe71025) | [Open](http://localhost:11030/trace/89538ae868cae9d2b3545fde411ce31d) | [Open](http://localhost:11030/trace/335e4dd16b01cf67c21b82e084053e1b) | [Open](http://localhost:11030/trace/6f07cadb058bc5f3fdabad8e768c4a1e) |
| Group | [Open](http://localhost:11030/trace/f8d80406d4635866e48ae6a8cb85c7a6) | [Open](http://localhost:11030/trace/bffaf1497c914537bc884689d7679d7f) | [Open](http://localhost:11030/trace/11427bdf696a06b59e3cc83b51225c33) | [Open](http://localhost:11030/trace/b1da98a0e16a9938be55d4747a88b836) |
| Membership | [Open](http://localhost:11030/trace/29bf2b24fc39bd063fecab7024ea7128) | [Open](http://localhost:11030/trace/2165bb46780691bc31389f8787f10ce9) | [Open](http://localhost:11030/trace/c4a8db4b34edb6dbf36b19e0d6c6cbb8) | [Open](http://localhost:11030/trace/36375704b2e43902eaab2fb8167848a0) |
| Organization relationship | [Open](http://localhost:11030/trace/31e9bd892d35fd7cdfff166d32ec69a2) | [Open](http://localhost:11030/trace/2b7cb9e8c26700f2a5f79190b91127f3) | [Open](http://localhost:11030/trace/50da5a6eb6b84f54e389312098e8c409) | [Open](http://localhost:11030/trace/5e920fe985220b713a21f4062aeb80b6) |
| Users count | [Open](http://localhost:11030/trace/dad5b355f211a20e9221c7582b90277a) | [Open](http://localhost:11030/trace/f5dd7fbc7b24ea670cd7d1157a773ef8) | [Open](http://localhost:11030/trace/7b268627c13da7ebf446054106252d31) | [Open](http://localhost:11030/trace/823794c58ec613aa84bb4687cd07c16f) |
| Groups count | [Open](http://localhost:11030/trace/a9f016130295e74e39d039a876da19ff) | [Open](http://localhost:11030/trace/fdbd0c2576a642250ca82b7647db3848) | [Open](http://localhost:11030/trace/12835ce44971e86a15f3f26508a5f661) | [Open](http://localhost:11030/trace/6340177c2f146376ae897dba2c06f0f4) |
| Organization | [Open](http://localhost:11030/trace/9e034d4a0d01eb9e01d6ea20a9e0bcb0) | [Open](http://localhost:11030/trace/72722aea5438aaac5e07c5de793ce25e) | [Open](http://localhost:11030/trace/208bdbbe513d677ecc5a3e5c26896826) | [Open](http://localhost:11030/trace/584c71f4b3d75e118111d29cf39413fa) |
| Organization account count | [Open](http://localhost:11030/trace/e1a4cdf5bc1656944c6070ed0e6d5b61) | [Open](http://localhost:11030/trace/b43e30f8312c10703fb7c305c0ec7d8b) | [Open](http://localhost:11030/trace/fb0fb8da1d53565c552a7628d542d395) | [Open](http://localhost:11030/trace/c4a34aeac816586cb2051d7501476d6a) |
| Hierarchy | [Open](http://localhost:11030/trace/a7eaac280ae41a0e350bdcef6b802c3d) | [Open](http://localhost:11030/trace/1e985c654ff3b1fb38288471b663b1b0) | [Open](http://localhost:11030/trace/9fc00013150f39f128a0faa5b821c9d2) | [Open](http://localhost:11030/trace/d7bad7827b23666f31615e2dfc01c48e) |
| Organization account IDs | [Open](http://localhost:11030/trace/c35c316be8d6a36d14e2f86148564973) | [Open](http://localhost:11030/trace/78590c9ffe1a4fe766f367a5b561011a) | [Open](http://localhost:11030/trace/06161b37c2d37b27bdf94e42057dc710) | [Open](http://localhost:11030/trace/c1bf9c77c51e53d5cd175325631b4abc) |
| Organization context | [Open](http://localhost:11030/trace/546b959c4a0b2d2ebcd2b81ffd7f41b5) | [Open](http://localhost:11030/trace/ea7caec7564b92fcc42e9acd136a69e9) | [Open](http://localhost:11030/trace/2073dde7cba9a2edee766db641208e60) | [Open](http://localhost:11030/trace/93c26ff1e3010eed258f26852e7cf098) |
| MSP page | [Open](http://localhost:11030/trace/72d453f90b66fa5003a8b3428bc01746) | [Open](http://localhost:11030/trace/2c0439610ff37eabdea14ce11d66999c) | [Open](http://localhost:11030/trace/005bb36d588593ef0140fb4db34ec1c5) | [Open](http://localhost:11030/trace/a6b79e6234dd6f34a835b956a9597f0b) |
