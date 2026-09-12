# Request timing in Jaeger

All six Rails projects enable controller tracing. The account-auth role inherits
the account implementation and exports its own service identity. Queue workers
load the same Ruby helpers but do not create web spans unless they serve web requests.

Typical trace ancestry:

```text
caller HTTP span
└─ GET /route (existing Rack span)
   └─ Controller#action
      └─ authorization, SQL, HTTP, rendering, application phases
```

The existing `rack.response.commit_to_close` span remains. Do not sum nested or
overlapping spans as independent work.

## Measured boundaries

Controller spans wrap `process_action` on both `ActionController::Base` and
`ActionController::API`, including before/around/after callbacks, authorization,
action execution and synchronous rendering. Exceptions retain their original
behavior and are recorded on the controller span. Middleware and deferred body
enumeration are outside the controller interval.

Controller durations include monotonic elapsed milliseconds. Cross-process span
timestamps use each process's wall clock.

The custom Puma hooks and instrumented Thruster build were removed after IPv6
was identified as the cause of the timing variability. Services use the standard
Thruster gem launcher. Historical traces may still contain Puma and Thruster spans;
[the earlier verification snapshot](../reports/summary/request-tracing-2026-09-11.json)
records the instrumentation that was active when those traces were captured.

## Configuration

These environment switches default to enabled; set one to `false` and restart
the affected process to disable that layer:

| Variable | Layer |
| --- | --- |
| `IAM_TRACE_CONTROLLER_PHASES` | Controller spans |
| `IAM_TRACE_HTTP_PHASES` | Custom Ruby HTTP phases |

These switches do not disable the existing automatic Rack/SQL/HTTP tracing.
Pass them to container environments through the appropriate Compose override.

The identical helper copies are deliberate: Rails services have isolated Docker
build contexts. `test/tracing_configuration_test.rb` checks for drift.
Use `./dc_dev`, `./dc_test` or `./dc_prod` for rebuild/restart operations.

## Validation

`test/integration/trace_server_integration.rb` runs real Puma keep-alive requests
through controller callbacks, asserting span parentage, actor/body/baggage
preservation, exceptions, the controller switch, and absence of OpenTelemetry
context errors. Run it using the installed image:

```sh
docker run --rm --entrypoint bundle -v "$PWD:/workspace:ro" \
  parent_account_id/user-management-service exec ruby \
  /workspace/test/integration/trace_server_integration.rb
```
