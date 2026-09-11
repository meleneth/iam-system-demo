# Trace instrumentation implementation — 2026-09-10

Implements the application changes from [the displayed-trace follow-up](displayed-trace-instrumentation-follow-up-2026-09-10.md). Code, integration, and real-Puma checks pass. Full benchmark acceptance and pre-Rack attribution remain open. Historical exports and the viewer are unchanged.

## Process identity

Every Rails initializer honors `OTEL_SERVICE_NAME` and exports hostname/PID as `service.instance.id`, plus `process.pid` and `deployment.role`. Compose gives `account-auth-service` its own name and `authorization-account-lookup` role while retaining the account-service environment. Queue workers have the `queue-worker` role and individual instance identities; other web processes default to `web`.

## Client and application phases

Faraday's existing client span remains. Its supported `enable_internal_instrumentation: true` option is required to expose lower-level phases; it also exposes the existing nested Net::HTTP client span. Downstream trace propagation uses that inner span.

Net::HTTP 0.6.0 hooks measure:

- `http.connection.connect`: the whole connection operation, including DNS/TCP and TLS where applicable, not DNS or TCP separately.
- `http.connection.prepare`: transport preparation/reconnection, recording prior socket reuse, logical destination, and available socket peer address/port.
- `http.request.write`: request execution/writes and known string-body bytes. An Expect/Continue wait can fall within this operation when that HTTP feature is used.
- `http.response.headers.wait_and_read`: waiting for and parsing status/headers, including informational responses. This is not a first-byte timestamp.
- `http.response.body.read`: body consumption, with buffered byte count when known. Buffered consumption does not imply those bytes arrived during this interval.

Each phase carries `phase.elapsed_ms` from a monotonic clock in addition to span timestamps. Nested intervals must not be summed. Setting `IAM_TRACE_HTTP_PHASES=false` in a process disables custom HTTP phase span creation, but not the other application/Rack changes or the nested automatic client span; it is not a full baseline-overhead switch.

The account-to-organization lookup separates JSON encoding, response parsing, and result materialization, with scope/byte counts rather than actor IDs or raw bodies. The existing actor header is retained, and Faraday/Net::HTTP propagate the active trace context.

The organization endpoint separates parameter access/validation, authorization, membership materialization, cache lookup/decode, miss materialization, payload construction, and serialization. Account, user, and group collection endpoints expose authorization, result materialization, and serialization. Account hierarchy assembly has a separate span. Existing SQL tracing and actor-scoped authorization semantics remain intact. The `organization_accounts.params.parse` span measures parameter access, permitting and validation; Rails may already have decoded the raw JSON body before that controller phase, so raw body decoding is not independently isolated.

## Rack/Puma lifecycle and ingress limits

Rack lifecycle hooks load from `config/boot.rb`, before Rails/Puma select their middleware backend. Loading them only from an initializer was insufficient on the server boot path. The implementation uses the installed Rack Events callbacks without replacing response bodies:

- `rack.application.entry`: the tracing handler has established the server context, before the application runs.
- `rack.response.ready`: the application returned its response.
- `rack.response.commit_to_close`: the interval from response commit to body close, including server handoff/buffering/handling within those boundaries.
- `rack.response.closed`: body-close lifecycle completion.
- `rack.response.body.enumeration.begin`: an optional event when Rack's `on_send` callback runs. Puma can consume array bodies without calling it, so it is not the start boundary of the response phase.

The response phase finishes before the existing server span. These callbacks do not establish socket arrival, socket-write boundaries, or downstream receipt.

The Dockerfiles run Thruster 0.1.14 on port 80 in front of Rails/Puma on target port 3000. Its bundled documentation provides debug logging but no documented trace-correlated receive/forward/body-ready/queue callbacks. Proxy receive/forward, request-body availability before Rack, and Puma queue entry/dequeue remain unmeasured. No proxy/queue spans or timestamps are invented. The original 37.479 ms pre-Rack gap remains unattributed.

## GraphQL parentage

Dataloader explicitly attaches the scheduling fiber's OpenTelemetry context in each new fiber and detaches it during cleanup. A query tracing hook replaces the controller's earlier `otel_ctx` with the live multiplex context. This gives source batches a stable parent/context key without changing batching keys per resolver. Verified with the actual GraphQL 2.5.11 / OpenTelemetry GraphQL 0.29.0 plugin, including request isolation.

## Validation

- Root regression suite: 34 tests, 142 assertions.
- HTTP/Dataloader regression suite: 4 tests, 35 assertions; payload/actor preservation, connection reuse, monotonic durations, exceptions, disabled HTTP phases, and request isolation.
- Actual-plugin integration checks: Faraday/Net::HTTP nesting and propagation; GraphQL parentage; Rack lifecycle, body closing, response contents, and context preservation.
- Real Puma HTTP check using the final source files: HTTP 200, trace `861707450e4cb65fa2c17a17dd17e45b`, three archived spans including `rack.response.commit_to_close` and the entry/ready/closed events. The array body correctly bypassed the optional enumeration event.
- Final rebuilt Compose stack: HTTP 200, trace `926abc3e136b59a80dc4fd7e97f15119`, with the commit-to-close span and entry/ready/closed events verified in Jaeger. The local application services remain running with capabilities mode, Redis disabled and batch size 1000.
- Compose identity/environment merging, actual SDK resource attributes, Ruby syntax, and whitespace checks passed.

The HTTP/Rack helper copies are intentional because services have isolated Docker build contexts. A regression check verifies all six copies agree and hooks load at boot.

Run the bundled checks without a Rails boot or databases:

```sh
ruby -e 'Dir.glob("test/*_test.rb").each { |p| require_relative p }'
for check in trace_instrumentation_test trace_http_integration trace_graphql_integration trace_rack_integration; do
  docker run --rm --entrypoint bundle \
    -v "$PWD:/workspace:ro" parent_account_id/user-management-service \
    exec ruby "/workspace/test/integration/${check}.rb"
done
```

## Full workload replay: acceptance still open

The production demo was initially stopped. Existing databases, caches, collector, and application services were started through `./dc_prod`. Both workload attempts used the original GET, organization and actor, capabilities mode, Redis disabled, batched retrieval, and batch size 1000. Base revision remains `c4752dcbff5cf99de65ee3bd846563a302289bde` plus these uncommitted changes.

| Attempt | Trace ID | Spans | Client result |
| --- | --- | ---: | --- |
| Original archive | `f0c3a4723a2eb0186f040ef52dd0ed08` | 22,212 | HTTP 200; 27.266361 s; 4,714,970 bytes |
| Instrumented replay 1 | `319972ddbe1f23390cdbb68d338e3a38` | 74,707 | curl 52 / HTTP 000; empty reply after 42.403317 s |
| Instrumented replay 2 | `9b81f1f7059ae0229f8e6859be30226f` | 74,707 | curl 52 / HTTP 000; empty reply after 44.149914 s |

Both new traces archived completely, with seven distinct service names and no recorded error spans. Rails/server spans report HTTP 200, but the client did not receive a successful response. Thruster documents a default 30-second write timeout; its involvement in the empty replies is not established by these traces. The two full replays preceded the final Rack boot/lifecycle corrections, which were then verified separately through real Puma.

Under the final `POST /group_users/search` in replay 1, the account-auth organization lookup is span `8f96d94f7842bab5`: scope count 1, 8.264 ms. Its Faraday call is 7.901 ms, connection operation 2.094 ms, write 0.428 ms, header wait/read 4.786 ms, and body read 0.150 ms. The nested organization handler is 3.640 ms. These intervals overlap. The ancestry matches group-service → capabilities → account-auth → organization-service.

Local artifacts are under `reports/raw/trace-instrumentation-20260910/` and `reports/raw/trace-instrumentation-20260910-final/`: effective runtime settings, client results, trace exports/status, selected phase summaries, and Puma verification traces.

The 27.3 s versus 42–44 s comparison is not calibrated overhead: process/database startup and host conditions were not controlled as an A/B experiment. Outstanding acceptance work is a successful full-response/cardinality check, exact reproduced account-ID payload capture, overhead measurement, the original warm GraphQL replay, and pre-Rack ingress attribution. These findings do not explain the old gap or close the original benchmark acceptance criteria.
