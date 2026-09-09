# Article benchmark readiness — 2026-09-09 follow-up

The audit compared this repository with the six-part GraphQL Auth Explosion
series and Developer Affordances in `~/Documents/whirred-io`. The requested
implementation follow-up is complete; controlled article measurements remain to
be collected.

## Implemented following the audit

- Account retrieval failures and incomplete/duplicate/unexpected account sets
  fail organization partitions and GraphQL collection loads. Missing membership
  groups fail explicitly. Missing/denied GraphQL reads report errors.
- Organization GraphQL accounts use the same validated Dataloader source.
- Retrieval chunks and organization/MSP partitions use `IAM_DEMO_BATCH_SIZE`
  (default 1000, valid range 1–10000). Large Account/hierarchy/count requests use
  JSON POST bodies. User/Group count sources preserve actor headers.
- Each cold workload gets an independent Redis flush. Each warm workload gets a
  priming run. Continuation pages remain together, and organization walks run to
  completion. Failed responses, GraphQL errors, timeouts, and configuration
  mismatches remain visible in outcomes and the process exit code.
- Every benchmark request gets a sampled trace ID. Jaeger JSON and export status
  are archived after the complete workload; missing/incomplete exports fail the
  run while preserving available evidence.
- `./analyze_databases.sh [dev|test|prod]` uses the repository wrappers to refresh
  statistics in every connectable non-template PostgreSQL database.

Per user direction, **queue count reaching zero is sufficient seed readiness**.
No additional dataset-readiness gate or database reconciliation was added.
Run ANALYZE after queue drain, outside measured samples.

## Validation

All service tests were run through `./dc_test`:

- User Management: 27 tests, 89 assertions, passing.
- Organization MSP pagination: 3 request examples, passing.
- User and Group JSON count endpoints: 2 request examples, passing.
- Harness/export checks: 7 tests, 30 assertions, passing. They cover independent
  cold repetitions, warm priming,
  multi-page walks, timeout preservation, trace correlation, delayed/incomplete
  export, export failure, and running-setting mismatches.
- A real GraphQL request was exported from test Jaeger as a six-span JSON trace.
- ANALYZE completed across all five PostgreSQL services in the test stack.

The smoke trace is validation, not article performance evidence. Span settling
and parent-reference checks cannot prove the telemetry pipeline dropped no spans.

## Collection still needed

| Article | Evidence to collect |
| --- | --- |
| CTE | Same target: parent walk versus CTE, depth sweep, Redis off |
| Retrieval | Same organization/actor: serial versus batched, fixed auth mode |
| Authorization | Same workload: capabilities versus /can, initially Redis off |
| Cache | Disabled, independently cold, and primed warm; concurrent cold probes |
| Smart APIs | Same target set: individual versus batched hierarchy calls |
| Dataloader | Actual downstream counts across batch boundaries and workload sizes |
| Million Users | End-to-end generation duration, worker configuration, resource use |

Keep single-organization scaling separate from MSP fan-out across client
organizations. Preserve raw responses, traces, runtime configuration and dataset
identity. Historical LocalStack/Goaws claims need their own supporting evidence.

Remaining broader work includes organization-count multi-key support, an explicit
GraphQL concurrency control, multi-actor alias/concurrency coverage, and legacy
account-page cleanup. These were not part of this implementation request.
Event-driven invalidation remains an explicit non-goal; caches use a 300-second
TTL. The article drafts and historical TODO sections need reconciliation with
these changes before publication. See `REPRO_INSTRUCTIONS.md` for current commands.
