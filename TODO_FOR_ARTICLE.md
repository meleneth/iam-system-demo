# Article Evidence TODO

This file tracks evidence work needed by the whirred.io GraphQL Auth Explosion
case-study articles. It is deliberately separate from implementation TODOs for
the demo itself.

## Part 2: Multiple Object Retrieval

Status: blocking article completion

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
