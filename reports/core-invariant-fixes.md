# Core invariant audit fixes

This change addresses the five divergences found in the follow-up audit against [CORE_INVARIANTS.md](../CORE_INVARIANTS.md).

- Organization HTML partitions fetch groups by the explicit memberships of the returned users. A group's owning account can be on another page. Group reads retain the requesting actor and propagate authorization failures.
- Organization-account relationship listings and individual reads share the same rule: an organization account-list grant on the row's organization or `account.read` on its account. Filters select rows; they do not add permission requirements. Every returned row must pass. Organization decisions are reused within the response.
- Capability lookups normalize UUIDs before resolving ownership/hierarchy facts and constructing cache keys. The batched account permission evaluator preserves the spelling of requested IDs in its returned set, maintaining the `/can` caller contract.
- Virtual provider paths retain the existing 100-account limit, enforced against each requested path independently of batch preloading. Both individual and batched over-limit requests raise the existing depth error. Missing facts and cycles still fail closed; fetch rounds remain bounded.
- Capability cache reads and writes tolerate Redis errors and return authoritative evaluation results. Errors resolving actual membership or relationship facts still propagate.

Authorization caches now use `group-grants-v2` so decisions from the previous resolver cannot bypass the corrected behavior. No schema migration is needed for these fixes.

## Regression coverage

Service tests cover cross-account memberships across pages in both retrieval modes, preservation of actor headers, denied group reads, organization-only/account-only/no-grant relationship lookups, mixed unauthorized collections, canonical UUID cache reuse, provider paths at and beyond the depth limit (including missing final facts), and Redis read/write failures with allowed and denied targets.

The persisted integration fixture now places an MSP administrator's group on its physical parent account, allowing the HTML regression to exercise a group owned by an account on an earlier page. New integration checks also exercise uppercase UUIDs and account-only relationship lookups.

Validation completed in the isolated test stack:

| Check | Result |
| --- | --- |
| Authorization-service full RSpec suite | 60 examples, 0 failures |
| Organization-service full RSpec suite | 37 examples, 0 failures |
| User-management full Rails test suite | 29 tests, 94 assertions, 0 failures/errors |
| `/can`, Redis disabled, serial retrieval | 21 cross-service examples passed; live correctness gate and hierarchy identity comparison passed |
| Capabilities, Redis enabled, batched retrieval | 21 cross-service examples passed; live correctness gate and hierarchy identity comparison passed |
| `git diff --check` | Passed |

The service suites run through `./dc_test run --rm --no-deps <service>` with `bundle exec rspec` or `bin/rails test`. The two integration runs use `scripts/test_authorization_boundaries.sh` with the corresponding `AUTHORIZATION_CHECK_MODE`, `GLOBAL_IAM_DEMO_USE_REDIS`, and `IAM_DEMO_RETRIEVAL_MODE` environment variables. That script uses the repository test wrapper and stops its temporary service containers when it exits.

The two integration configurations cover both authorization APIs, cache enabled/disabled, and serial/batched retrieval; this is not an exhaustive combination matrix. Healthy cache reuse and Redis failure behavior also have focused service coverage. These checks are not a full-size dataset rebuild or new benchmark evidence. Development and production were not deployed.
