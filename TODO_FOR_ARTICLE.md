# Article Evidence TODO

This file tracks evidence work needed by the whirred.io GraphQL Auth Explosion
case-study articles. It is deliberately separate from implementation TODOs for
the demo itself.

## September 2026 implementation follow-up

See [BENCHMARK_READINESS_AUDIT.md](BENCHMARK_READINESS_AUDIT.md) for the current
implementation/validation status and accepted scope. The sections below retain
historical audit requirements: retrieval failure handling, environment-sized
chunks, organization Dataloader account loads, independent cold samples, trace
JSON archival, and database ANALYZE are now implemented. Queue drain remains the
accepted seed-readiness convention. Controlled article measurements are still
outstanding.

## Part 2: Multiple Object Retrieval

Status: blocking controlled benchmark and trace evidence

### Why this experiment is needed

The target workload is the full-organization User Management screen, not the
older single-account page. The screen loads users and related IAM data across
the accounts belonging to an organization. This is the workload the synthetic
system was built to reproduce.

The original failure was a distributed N+1 visible in Jaeger: local-looking
ActiveResource access repeatedly crossed service boundaries. Hierarchy walking
also followed `account.parent` across the network. As complete authorization was
added to every collection load, the full-organization request reproduced the
known failure and took on the order of minutes or failed before responding.

The repository can currently vary authorization strategy, Redis usage, and
server-side page size, but it cannot isolate serial versus batched object
retrieval on the same full-organization endpoint. Historical serial code and
experimental account routes are not a controlled comparison for the current
organization-wide workload.

### Required implementation

Implementation update: the full-organization partition now supports
`IAM_DEMO_RETRIEVAL_MODE=serial|batched`, passes the setting through Compose,
reports the mode in its payload, and has a bounded equivalence test covering
accounts, users, groups, memberships, actor propagation, and downstream call
shape. The focused benchmark entry point and run metadata are implemented; the
controlled runs remain outstanding.

- Add an explicit runtime retrieval switch, provisionally:

  ```text
  IAM_DEMO_RETRIEVAL_MODE=serial|batched
  ```

- Apply the switch to the full-organization User Management data path.
- Keep both modes behaviorally equivalent:
  - same organization and account set
  - same actor identity propagated as `pad-user-id`
  - same returned accounts, users, groups, and group memberships
  - same partition/continuation behavior
  - same authorization semantics
- `serial` must intentionally issue one downstream object request at a time so
  Jaeger reproduces the distributed N+1.
- `batched` must use the existing collection/search APIs.
- Do not use `IAM_SYSTEM` to make the serial path complete.
- Pass the setting through the Compose service environment and document it in
  the reproduction instructions.
- Add tests proving both modes return equivalent data for a small fixture.

### Benchmark integration

- Teach `benchmark_demo.sh` to record the retrieval mode in its output metadata.
- Add a focused full-organization benchmark that can run independently of the
  larger matrix.
- Use the same fixture, endpoint, actor, authorization mode, Redis mode, server
  process configuration, and batch size for each serial/batched comparison.
- Record:
  - HTTP status or failure mode
  - wall-clock time
  - response size
  - accounts, users, groups, and memberships returned
  - partition/page count
  - downstream request count by service
  - authorization request count
  - Jaeger trace ID or exported trace artifact
- Capture at least cold-after-startup and warm runs. Separate process startup
  cost from cold-cache cost.
- Use a bounded fixture first so the serial mode completes. Increase cardinality
  until the response crosses the configured timeout; record timeouts as censored
  results rather than pretending they have a duration.

### Diagram evidence

- Part 2 contains structural Mermaid diagrams for one-object-per-request and
  collection-shaped retrieval.
- After benchmarking, annotate the surrounding prose with measured request
  counts and timings; do not place provisional numbers inside the diagrams.
- Confirm that the final endpoint and HTTP method labels match the implementation
  selected by `IAM_DEMO_RETRIEVAL_MODE`.
- Treat the retrieval APIs as constrained collection lookups, never as generic
  search. The two shapes to document are explicit primary-key arrays such as
  `GET /accounts?id[]=...` and join-key lookups such as
  `GET /users?account_id[]=...`.
- Derive every diagram URL, method, parameter name, and response shape from the
  relevant source revision or a captured request. Do not substitute a plausible
  generic endpoint name.
- Preserve a representative Jaeger screenshot or trace export showing the serial
  fan-out. A real trace should accompany, not replace, the conceptual diagram.

### Initial controlled matrix

| Retrieval mode | Authorization mode | Redis | Purpose |
| --- | --- | --- | --- |
| `serial` | `capabilities` | off | Reproduce the worst architectural composition. |
| `batched` | `capabilities` | off | Isolate the benefit of bulk object retrieval. |
| `batched` | `can` | off | Isolate the narrower authorization contract. |
| `batched` | `can` | on | Show the optimized warm-system path. |

For the Part 2 article, the primary comparison is the first two rows. The later
rows belong principally to the authorization and caching articles, but collecting
them in the same harness preserves a reusable baseline for the series.

### Existing evidence to preserve

- Git history contains the original serial account retrieval:

  ```ruby
  org_accounts.map { |org_account| Account.find(org_account.account_id) }
  ```

- Git history contains the original cross-network parent walk:

  ```ruby
  while current_account.parent_account_id
    parent_account = Account.find(current_account.parent_account_id)
    current_account = parent_account
  end
  ```

- Existing runtime controls:
  - `AUTHORIZATION_CHECK_MODE=can|capabilities`
  - `GLOBAL_IAM_DEMO_USE_REDIS=true|false`
  - `IAM_DEMO_BATCH_SIZE`
- Existing fixtures include deep-chain, wide-organization, dense-account, and
  10k/50k/100k fan-out workloads.
- Existing benchmark results already demonstrate organization-wide requests on
  the order of minutes and a capabilities-mode failure. Preserve those artifacts,
  but do not use them as the serial-versus-batched comparison because they do not
  isolate retrieval mode.

### Article facts already established

- This is a synthetic reconstruction of a known architectural failure.
- The intended workload was always organization-wide User Management. Some
  obvious N+1 fixes landed before that reconstruction was fully implemented.
- Ordinary product requests operate as one logged-in user in one account
  context. A cached capability list for that account is bounded and fast, even
  if searching the array client-side is inelegant.
- User Management has fundamentally different cardinality: one administrator
  evaluates users spread across many accounts in an organization.
- Complete authorization therefore reproduced the expected collapse instead of
  invalidating the earlier prediction.
- The article must distinguish observed traces, known architectural constraints,
  and measurements produced by the final controlled experiment.

### Completion gate

Part 2 is unblocked when the retrieval switch is implemented, equivalence tests
pass, the controlled benchmark has been run, and stable timing/trace artifacts
exist for citation.

## Part 3: Multiple Object Authorization

Status: blocking technical audit before article drafting

### Why this audit is needed

The first multi-account `/can` implementation used
`Authorization::AccountGrantChecker#authorized_for_all?`. It advanced through
all requested account hierarchies depth by depth and batched the grant checks at
each depth. The current `/can` implementation instead delegates to
`Authorization::Capabilities#account_ids_with_permission`, unions hierarchy
scope IDs, resolves matching grants as sets, and then requires every requested
account ID to be present in the authorized result.

The current path is security-critical and may have been substantially generated
or reshaped with LLM assistance. Do not describe it as the final correct
algorithm merely because the existing test suite passes. Audit it explicitly
against the intended authorization semantics and the earlier implementation.

### Authorization semantics to prove

- An account grant applies to that account and all descendants.
- A child grant never grants access to its parent.
- A grant never crosses sideways into a sibling branch.
- Duplicate requested IDs do not change the result.
- Every requested account must be authorized; one unauthorized account makes
  the complete `/can` request fail.
- An empty input follows an intentional, documented policy.
- Missing, malformed, unknown, or cross-organization account IDs fail safely.
- Hierarchy responses that are missing, duplicated, reordered, or shorter than
  the requested ID list cannot authorize the wrong target.
- Cycles or unexpectedly deep hierarchies cannot produce incorrect authority or
  unbounded work.
- A grant must match the actor, permission, and `Account` scope type exactly.
- `msp.*` grants do not leak into ordinary account-context authorization.
- `IAM_SYSTEM` remains limited to the internal hierarchy lookup and cannot be
  substituted for the real actor on the app-facing authorization decision.

### Implementation audit

- Compare `AccountGrantChecker#authorized_for_all?` and
  `Capabilities#account_ids_with_permission` with the same generated hierarchy
  and grant cases; prove semantic equivalence for native account grants.
- Verify the ordering contract of `Account.with_parents_batch`. The current code
  uses `account_ids.zip(Array(hierarchies))`; confirm that a response cannot be
  reordered or partially omitted in a way that associates one hierarchy with a
  different requested account.
- Verify that each returned hierarchy actually contains its requested target and
  only legitimate ancestors of that target.
- Review the set-union grant query for accidental upward or sibling authority.
- Review reflected MSP authorization separately. It must not weaken ordinary
  account semantics, and native authorization must not trust stale MSP headers.
- Verify all-or-nothing behavior at every collection controller, not only in the
  Authorization Service request spec.
- Review Redis cache keys, positive and negative caching, TTL behavior, actor and
  permission isolation, and behavior when Redis is disabled.
- Determine whether authorization changes require invalidation beyond the
  current five-minute TTL; record the demo limitation explicitly.
- Check behavior under concurrent requests and partial downstream failure.
- Run the relevant unit/request suites after adding the missing cases.

### Known test gaps at time of note

Existing tests cover several important examples: parent-chain capability
collection, rejection when any requested account lacks the permission, native
grants despite stale MSP headers, Redis-disabled checking, and filtering of
`msp.*` capabilities.

They do not yet constitute a proof of the current set-based algorithm. Add at
least:

- direct, parent, grandparent, child-to-parent denial, and sibling denial cases
- mixed authorized/unauthorized collections in different input orders
- duplicate IDs and overlapping hierarchies
- multiple permissions and multiple actors to detect cache/key contamination
- missing and reordered hierarchy responses
- Redis-on and Redis-off equivalence, including negative cache entries
- property-style comparison of the old depth-walk oracle and current set-based
  implementation over generated trees and grants

### Controlled evidence for the article

- Use the existing `AUTHORIZATION_CHECK_MODE=capabilities|can` switch against the
  same full-organization workload.
- Start with Redis disabled to isolate authorization API shape.
- Repeat with Redis enabled to show the operational path, but leave detailed
  cache analysis to Part 4.
- Capture wall time, completion/failure, authorization request count, hierarchy
  request count, database query count if available, and stable Jaeger traces.
- Re-run rather than relying solely on the existing short matrix. The current
  results already show capabilities-mode failure on the 10k fan-out, but the
  final article needs preserved configuration and trace artifacts.

### Diagram evidence

- Part 3 contains structural Mermaid diagrams for:
  - one capability-array response in the ordinary single-account context
  - repeated capability-array retrieval in organization-wide User Management
  - downward-only grant inheritance
  - one all-or-nothing `/can` request over an account-ID set
- During the implementation audit, verify that the hierarchy response mapping in
  the `/can` diagram matches the actual API contract rather than the current
  positional `zip` assumption.
- Add representative Jaeger evidence for capabilities mode and `/can` mode after
  the controlled rerun. Keep conceptual request-shape diagrams distinct from
  measured trace evidence.

### Agreed article structure

1. Batching retrieval exposed the next N+1.
2. User Management breaks the normal single-account permission model.
3. The original contract retrieved complete capability arrays and searched them
   client-side.
4. Account authority is directional: downward, never upward or sideways.
5. Authorization becomes a set operation over query-generated account IDs.
6. All-or-nothing denial protects an invariant; it is not record filtering.
7. Explain the audited evolution from depth-wise checks to set-based resolution.
8. Compare capabilities and narrow `/can` modes with controlled evidence.
9. Hand off cache mechanics and invalidation limitations to Part 4.

### Article facts already established

- In ordinary product use, the actor operates in one account context. Fetching
  and caching that account's capability list is bounded and fast, even though a
  client-side array search is inelegant.
- Organization-wide User Management checks one administrator against records
  spanning many accounts, so the same contract acquires radically different
  cardinality.
- Requested IDs normally come from authorized relationship lookups rather than
  arbitrary user input.
- One unauthorized result is therefore an invariant violation or service
  disagreement. Silently filtering it would conceal the failure.

### Completion gate

Part 3 is unblocked when the current set-based implementation has been audited,
the missing semantic tests pass, the controlled auth-mode benchmark has been
rerun, and stable trace artifacts exist for citation.

## Part 4: Redis Cache, per service

Status: blocking controlled cache evidence

### Why this work is needed

The article originally described `Authorization::AccountGrantChecker` and its
`user_grants:<user_id>:<permission>` Redis set with pipelined `SISMEMBER`
checks. That class had unit tests, but no production path called it. The live
`/can` controller delegates to
`Authorization::Capabilities#account_ids_with_permission` instead.

The live implementation has a different cache shape:

```text
can:<user_id>:Account:<permission>:<account_id>
```

Before the implementation cleanup, it resolved cache misses with set-based
database and hierarchy work while its Redis `GET` and `SET` operations occurred
in ordinary Ruby loops. The article could not accurately claim that the live
authorization cache path was pipelined at that revision.

Implementation update: `AccountGrantChecker` was removed as dead code. The live
`Capabilities#account_ids_with_permission` path now pipelines multi-account
reads and computed-miss writes, preserves positive and negative entries, and
falls back to authoritative computation when Redis pipelines fail. Focused
tests cover mixed hits/misses, duplicate and empty inputs, and pipeline failure.
Concurrent cold-request behavior remains to be measured. Event-driven
invalidation is deliberately outside the demo scope and remains an article
limitation.

### Completed implementation cleanup

- Removed the dead `AccountGrantChecker` implementation and its isolated tests.
- Pipelined the live authorization cache reads and writes in
  `Capabilities#account_ids_with_permission`, while preserving:
  - positive and negative cache entries
  - user, scope type, permission, and account isolation
  - Redis-enabled and Redis-disabled behavioral equivalence
  - all-or-nothing authorization semantics at the `/can` boundary
- Added focused tests that assert one Redis pipeline for a multi-account read and
  one pipeline for writing computed misses, rather than one Redis round trip per
  account.
- Verified mixed hit/miss behavior, duplicate account IDs, empty inputs, and
  Redis pipeline failure fallback.
- Kept `GLOBAL_IAM_DEMO_USE_REDIS=true|false` capable of exercising equivalent
  live paths for controlled comparison.

Concurrent cold-request behavior remains to be verified with the controlled
workload.

### Cache inventory to verify

Document and test the three service-owned derived-result caches currently in
the demo:

- Account Service:
  - key: `account_with_parents:<account_id>`
  - value: the requested Account and its ancestor chain
  - TTL: 300 seconds
  - batched Redis reads/writes through a pipeline
  - invalidation registry: `org_cachekeys:<organization_id>`
- Organization Service:
  - key: `account_ids_by_organization:<organization_id>`
  - value: account-ID membership list, never remote Account objects
  - TTL: 300 seconds
  - batched multi-organization Redis reads/writes through a pipeline
- Authorization Service:
  - key: `capabilities:<user_id>:<scope_type>:<scope_id>` for complete
    capability arrays
  - key: `can:<user_id>:Account:<permission>:<account_id>` for narrow boolean
    decisions
  - TTL: 300 seconds for both
  - live multi-account `/can` cache reads and computed-miss writes are pipelined

Confirm that the inventory matches the final live revision. The article should
say that services cache derived results from data they own, not make the broader
and inaccurate claim that every object-owning service caches its objects.

### Explicit non-goal: event-driven invalidation

Event-driven invalidation for account hierarchy, organization membership, and
capability-grant changes is not implemented and is not required for this demo or
the article evidence. The articles should call this out directly as a production
requirement. The implemented 300-second TTL is the demo's stale-data bound; the
existing `org_cachekeys:<organization_id>` registry demonstrates possible
targeting but does not imply that invalidation workers exist.

### Controlled evidence for the article

- Run the same organization-wide User Management workload with Redis disabled,
  cold, and warm.
- Hold fixture, actor, authorization mode, retrieval mode, server process model,
  and batch size constant.
- Record wall time, HTTP outcome, Redis command/round-trip counts by cache,
  cache hits and misses, database queries, downstream requests, and stable
  Jaeger trace IDs or exports.
- Show which multiplier each cache contains:
  - repeated ancestry computation
  - repeated organization-membership expansion
  - repeated authorization computation for the same user/account/permission
    contexts
- Use fixed-revision source permalinks in the article. Do not link to `main`.

### Completion gate

Part 4 is unblocked when the dead/live authorization-cache discrepancy is
resolved, live multi-account cache operations are demonstrably pipelined,
cache behavior tests pass, the controlled disabled/cold/warm comparison has
been captured, and the article can cite a fixed source revision while clearly
documenting TTL-only coherence as a demo limitation.

## Part 5: Smart APIs

Status: blocking trace evidence

### Hidden hierarchy N+1

Account Service already exposes the collection-shaped hierarchy endpoint used
by `Account.with_parents_batch(account_ids)`:

```text
GET /accounts_with_parents?account_ids[]=...
```

The endpoint passes the complete ID set through the pipelined ancestry cache and
the set-based recursive CTE. Authorization Service uses it in
`Authorization::Capabilities#account_hierarchy_ids_for`, and a User Management
controller also uses it for a multi-account request.

Two User Management GraphQL paths previously bypassed it:

- `Sources::AccountsWithParentsById#fetch` loops over its Dataloader keys and
  calls `Account.with_parents` once per key.
- `Resolvers::AccountHierarchiesResolver#resolve` maps requested IDs through
  individual `Account.with_parents` calls.

That revision recreated a cross-network N+1 even though the batch endpoint
already existed. Worse, `AccountsWithParentsById` named its trace span
`Account.with_parents_batch(<count>)` while issuing the individual calls, so its
instrumentation described work that did not happen.

Implementation update: both GraphQL paths now use one batched hierarchy call,
map responses by requested target ID, preserve duplicates and caller order, and
report truthful trace attributes. Model and schema-level tests cover the real
root-to-target response contract, reordered, missing, duplicate, and empty
results, Account Service failure propagation, actor headers on both Account and
User requests, and OpenTelemetry context restoration. Captured trace evidence
remains outstanding.

### Required implementation

- Replace both per-ID GraphQL loops with one
  `Account.with_parents_batch(unique_account_ids)` call per GraphQL batch or
  resolver invocation.
- Preserve input ordering and duplicate-key behavior when mapping the batched
  response back to GraphQL/Dataloader results.
- Define and test behavior for missing IDs, partial responses, reordered
  downstream responses, empty input, and Account Service failure.
- Verify actor/header and OpenTelemetry context propagation on the one batched
  request.
- Make trace span names describe the operation actually executed. Add an
  attribute for requested unique ID count and downstream request count if the
  tracing conventions support it.
- Remove stale comments such as “Prefer a batched endpoint if you have it”; the
  endpoint exists and should be the required path.

### Tests and evidence

- Add unit tests proving each GraphQL path makes exactly one downstream Account
  Service hierarchy request for multiple account IDs.
- Assert result equivalence with the former serial path for a bounded fixture,
  including overlapping ancestor chains and duplicate requested IDs.
- Add a request or integration test that exercises the GraphQL field through the
  schema rather than testing only the source class in isolation.
- Capture before/after Jaeger traces or exported spans showing N downstream
  `GET /account_with_parents/:account_id` requests becoming one
  `GET /accounts_with_parents?account_ids[]=...` request.
- Verify the final article diagrams and fixed-revision source links against the
  corrected implementation.

### Completion gate

Part 5 is unblocked when both GraphQL hierarchy paths use the batch endpoint,
ordering and failure semantics are tested, instrumentation truthfully describes
the downstream operation, and preserved trace evidence demonstrates one network
request for a multi-account hierarchy load.

## Supporting cleanup: batching and concurrency controls

Status: implementation cleanup; no standalone article

The Async Madness article has been removed from the case-study spine. Bounded
concurrency remains an implementation detail of the GraphQL/Dataloader path,
and the legacy Accounts controller still needs removal, but neither justifies a
separate numbered article.

### Runtime controls

The live GraphQL `Sources::AccountById` implementation currently hardcodes:

```ruby
CHUNK_SIZE = 200
MAX_CONCURRENCY = 4
```

`IAM_DEMO_BATCH_SIZE` is already passed into User Management by Compose, but
this source does not consume it. There is also no environment control that
turns concurrent chunk retrieval on or off. `IAM_DEMO_RETRIEVAL_MODE` selects
serial versus batched object retrieval for the organization-wide controller; it
does not distinguish sequential batches from concurrent batches.

- Replace the hardcoded GraphQL chunk size with a validated, bounded value read
  from `IAM_DEMO_BATCH_SIZE`, with a documented default.
- Add an explicit defaulted concurrency control, provisionally:

  ```text
  IAM_DEMO_ASYNC=true|false
  IAM_DEMO_MAX_CONCURRENCY=4
  ```

- When async is disabled, preserve batching but execute chunks sequentially.
  Do not make “async off” fall back to one-record-per-request behavior.
- Validate zero, negative, non-numeric, and unreasonably large values rather
  than allowing `each_slice` or worker creation to fail unpredictably.
- Pass the controls through Compose, benchmark metadata, reproduction commands,
  and trace attributes.
- Add tests for serial retrieval, batched-sequential retrieval, and
  batched-concurrent retrieval with equivalent results.

### Remove the historical Accounts controller

`UserManagementService::AccountsController` is legacy code, but it is not
currently unused. The following routes still point to it:

```text
GET /accounts/:id
GET /slow_accounts/:id
GET /slowest_accounts/:id
GET /debug
```

The normal account page is linked from the front door and exercised by
`benchmark_demo.sh`; the slow routes are documented as comparison/debug views.
Its `fetch_accounts_async` method hardcodes five-ID chunks and creates one Async
task per chunk without a concurrency bound.

These pages no longer provide enough value to justify maintaining a second,
less representative retrieval and concurrency implementation. The
organization-wide User Management workload and its runtime retrieval controls
are now the canonical reproduction surface. Preserve historical source through
Git and article evidence rather than keeping the old paths executable.

- Remove `UserManagementService::AccountsController`.
- Remove all four routes listed above and any route helpers that become unused.
- Remove the controller's Account view and any assets used only by that view.
- Remove front-door links and fixture links that navigate to the legacy account
  page.
- Remove README and `FINAL_ARCHITECTURE.md` references to the comparison/debug
  endpoints.
- Remove the account-page probes and result labels from `benchmark_demo.sh`.
- Remove tests, helpers, and dependencies used only by this controller,
  including the direct `async` dependency if no supported runtime path still
  requires it.
- Confirm that the organization-wide User Management page, GraphQL demo
  queries, focused retrieval benchmark, and seed fixture links remain intact.
- Preserve historically useful slow-path snippets, commit references, and trace
  artifacts for the articles before deleting live code if they are not already
  recoverable from fixed Git revisions.

### Completion gate

This cleanup is complete when chunk size and concurrency are controlled by validated
defaulted environment settings, batched-sequential and batched-concurrent modes
are behaviorally equivalent and measurable, and the legacy Accounts controller
and its complete route/UI/documentation/benchmark surface have been removed.

## Part 6: GraphQL and Dataloader

Status: blocking Dataloader consistency and request-shape audit

### Why this audit is needed

The article currently claims that nested GraphQL fields use Dataloader sources
and collapse the result to roughly one downstream request for Accounts, Users,
Groups, and GroupUsers. The live implementation is uneven:

- `OrganizationType#accounts` manually retrieves organization membership and
  chunks Account requests instead of using a Dataloader source.
- `Sources::OrgAccountsCount` is a Dataloader source, but its client method
  explicitly rejects more than one organization ID.
- `UsersCountByAccount`, `GroupsCountByAccount`, and `OrgAccountsCount` accept an
  `as:` actor argument but do not apply it with `with_headers`; the instance
  variable is otherwise unused.
- `UsersByAccountId` and `GroupsByUserId` batch logical keys but split them into
  multiple downstream requests at hardcoded 200-ID boundaries.
- `GroupsByUserId` necessarily has two dependent stages: load GroupUser rows,
  then load the referenced Group rows. It is not literally one request for the
  entire nested relationship.
- The article's “Known Unevenness” example says
  `AccountsWithParentsById` iterates per key, but Part 5 fixed that path to use
  one batch hierarchy request.

Dataloader collects logical field loads; it does not guarantee one network
request unless each source preserves that batch shape when calling downstream
services.

### Required implementation audit

- Add or adopt an Account-by-ID source for `OrganizationType#accounts` so
  Account requests from organization fields participate in the same Dataloader
  batch as other Account loads where GraphQL execution permits it.
- Decide whether organization-account counts need true multi-organization
  batching. If so, add a collection-shaped Organization Service endpoint and
  make `OrgAccountsCount#fetch` issue one request for all collected keys. If the
  schema can only request one organization here, remove misleading Dataloader
  machinery and document the actual bounded shape.
- Apply `pad-user-id` explicitly in every source that accepts `as:`. Remove
  unused actor arguments only where the downstream endpoint is intentionally
  actor-independent.
- Make all source chunk sizes consume the validated Part 6 batch-size setting
  rather than defining unrelated hardcoded constants.
- Specify failure behavior per source: fail the GraphQL field/request, return
  `nil`, or return a partial collection. Do not silently mix policies.
- Verify output ordering, duplicate keys, missing records, and authorization
  denial for every source.
- Remove stale comments and generated scaffold commentary from resolvers and
  schema classes where it obscures the actual contract.

### Article and diagram requirements

- Add a real GraphQL query and variables from the demo fixtures; the current
  article contains empty “this query / these variables” placeholders.
- Diagram GraphQL's two phases separately:
  - logical field resolutions collected by Dataloader
  - actual downstream REST requests after chunking and dependent stages
- Use formulas or measured counts rather than “one request” when cardinality
  exceeds the configured batch size.
- Show that GroupUser retrieval must precede Group retrieval because the first
  response supplies the Group IDs for the second request.
- Explain that Dataloader preserves batching opportunities created by the REST
  APIs; it does not repair a source that loops over keys.
- Replace the stale `AccountsWithParentsById` warning with any unevenness that
  remains after this audit.

### Tests and evidence

- Add source-level tests asserting downstream request counts, actor headers,
  ordering, duplicates, missing records, and failure behavior.
- Add schema-level tests for a representative nested organization query.
- Capture request counts and Jaeger traces for a result below and above the
  configured batch size.
- Verify the trace shows each dependent stage and does not label multiple
  network calls as one batch operation.
- Use fixed-revision source permalinks in the final article.

### Completion gate

Part 6 is unblocked when every claimed Dataloader source has an explicit and
tested downstream request shape, actor propagation is correct, hardcoded chunk
sizes are removed, the representative nested query has preserved trace/request
evidence, and the article describes actual chunk and dependency cardinality
rather than promising one request per object type.
