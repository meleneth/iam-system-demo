# Group grants and virtual MSP inheritance

The baseline before this implementation is commit `c9808ca`. The authoritative contract is [CORE_INVARIANTS.md](../CORE_INVARIANTS.md).

## Implemented model

- `capability_grants` assigns `(permission, scope_type, scope_id)` to `group_id`. There is no `user_id` on active grants. A unique index prevents duplicate group grants and a check constraint restricts scopes to Account, Group and Organization.
- Authorization-service obtains explicit memberships from group-service. A grant is effective only when the actor belongs to its group. Multiple groups contribute additive grants; membership alone grants nothing.
- Physical `parent_account_id` ancestry stays inside each organization. The existing client hierarchy response remains client-only.
- Organization-service resolves an account’s MSP provider through `organization_accounts.organization_id -> msp_managed_organizations.client_organization_id`. The provider account and its physical ancestors become additional authorization scopes. Further provider relationships can be traversed; malformed and cyclic graphs fail closed.
- There is no `msp.admin.users` grant or role prerequisite. The provider and clients use ordinary Account capabilities. MSP pages require normal `account.read` on the provider and all returned targets; nested resources retain their own checks.
- Organization grants cover exactly their organization. Group grants cover exactly their group and combine with grants covering its owning account. Both `/can/Group/:permission` and single/batched Group capability APIs are supported. Group and membership reads accept `group.read` or owning-account `account.users.read`; mixed collections retain each target’s decision.
- Dedicated `group-auth-service` and `organization-auth-service` processes serve fact lookups from the same owning-service databases, alongside the existing account-auth-service. They have no published host ports. App traffic stays on ordinary services; fact lookups do not wait on workers already occupied by requests awaiting authorization.
- `IAM_SYSTEM_AUTH` is limited to membership, group-ownership and MSP-relationship fact endpoints. Normal resource requests retain the actor. Account-service’s existing internal `IAM_SYSTEM` parent lookup is unchanged.
- Final authorization caches use a new `group-grants-v1` prefix, so old user-grant allows cannot survive the model transition. Membership facts are memoized only within one authorization-service instance/request, not persisted in auth-service.

## Seed projection and migration

Migration `20260914000000` archives the former table as `legacy_user_capability_grants` and creates the group-owned table. Archived grants are never read by authorization. The migration intentionally does not guess a group for an old user grant: assigning such a grant to an existing multi-user group could expand authority.

The regular seed worker grants read capabilities to each account’s Users group and additional write capabilities to its Admins group. Group read grants belong to the corresponding groups; Admins receives group modification grants. The group worker projects explicit memberships and handles sequential event redelivery without adding another membership. Shared grant insertion is idempotent across multiple users in the same group. The old `scripts/create_user.rb` entry point now uses the supported queue-based seeder.

The resolved development, test and production Compose configurations were checked for matching owner/replica databases and environments, isolated fact URLs, and no published fact-replica ports.

Only the isolated test database was migrated during this implementation. Development and production databases were not migrated or reseeded. Deployment must coordinate the authorization-service schema/code and group/organization fact endpoints, then replay seed events using each owning service’s worker. Existing group membership must be present before collecting results. Do not use the archived user grants as an authorization fallback.

Before collecting new full-size benchmark results:

1. Apply the migration and updated services using the appropriate repository wrapper (`./dc_dev` or `./dc_prod`). Keep benchmark traffic stopped during the transition.
2. Rebuild/replay the intended fixed seed corpus through the normal seeder and workers. Record the corpus/manifest identity and wait for all projection queues to drain. Do not expect the new grant table to be populated by the migration itself.
3. Start measurement from a deliberate cold/warm cache state after seeding; requests made while projections are incomplete may have cached negative decisions for up to five minutes.
4. Run the cross-service regression matrix and the live correctness gate against the actual target stack/manifest before performance collection. Historical performance numbers do not measure this group-membership authorization model.

## Validation

The cross-service fixture now has shared group grants, explicit members and nonmembers, different permissions/scopes, two independent MSPs, provider ancestor grants, multiple client organizations, and client root/child/leaf/sibling accounts. Client roots have no provider parent links. A concurrent-read regression sends twelve group/MSP reads together to exercise worker isolation.

The tested configurations are recorded below. Each cross-service run also executes the live correctness gate and compares exact individual/batched hierarchy identities.

| Check | Result |
| --- | --- |
| `/can`, Redis disabled, serial retrieval | 18 examples passed; live gate and hierarchy identities passed |
| `/can`, Redis enabled, batched retrieval | 18 examples passed; live gate and hierarchy identities passed |
| Capabilities, Redis enabled, batched retrieval | 18 examples passed; live gate and hierarchy identities passed |
| Capabilities, Redis disabled, serial retrieval | 18 examples passed; live gate and hierarchy identities passed |
| Authorization-service specs | 50 examples passed |
| Group-service specs | 27 examples passed |
| Organization-service specs | 33 examples passed |
| User-management full test suite | 27 tests, 88 assertions passed |
| Repository root tests | 43 tests, 257 assertions passed |
| Full deterministic seed catalog, in-memory projection | 8 fixtures; 200,340 events; 161,018 accounts; 159,997 client-organization relationships; 1,027,837 group-grant rows before deduplication; passed |

`verify_group_seed_projection.rb` validates all deterministic seed events without writing queues or databases. It checks explicit grant recipients, absence of special MSP grants, consistent ownership, provider membership and physical parent boundaries. Run it with Rails loaded and the repository mounted read-only at `/workspace`:

```sh
./dc_test run --rm --no-deps -v "$PWD:/workspace:ro" user-management-service \
  bin/rails runner /workspace/scripts/verify_group_seed_projection.rb
```

The full catalog projection check is not a full-size database rebuild or benchmark. The persisted integration fixture and service specs are run sequentially because they share the test databases.

Raw validation output is recorded in [group-grants-validation](group-grants-validation/), including the four integration runs, service suites, root tests, seed projection and resolved Compose checks.
