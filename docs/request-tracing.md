# Request timing in Jaeger

All six Rails projects enable controller, Puma, and Thruster ingress tracing in
their container images. The account-auth role inherits the account implementation
and exports its own service identity. Queue workers load the same Ruby helpers but
do not create web spans unless they serve web requests.

Typical trace ancestry:

```text
caller HTTP span
└─ thruster.ingress               (<Rails service name>-ingress)
   └─ thruster.upstream
      └─ puma.request             (<Rails service name>)
         ├─ puma.queue.wait       (when dispatched through the thread pool)
         ├─ GET /route            (existing Rack span)
         │  └─ Controller#action
         │     └─ authorization, SQL, HTTP, rendering, application phases
         └─ puma.response.prepare_and_write
```

The existing `rack.response.commit_to_close` span remains. It overlaps server
response handling; do not sum nested/overlapping spans as independent work.

## Measured boundaries

* **Thruster ingress:** its HTTP handler starts after Go has parsed the request
  headers. The span wraps the existing logging, body limit, compression,
  sendfile, cache and proxy handlers through their return. It records handler
  entry/finish, HTTP status and the standard HTTP instrumentation attributes.
* **Thruster upstream:** the existing reverse proxy transport, including response
  body consumption. Events record connection acquisition/reuse, DNS/connect
  start/finish when those operations occur, headers written, request written,
  and the first response byte. A reused connection will not have new DNS/connect
  events. These events use Go's `net/http/httptrace` callbacks.
* **Puma request:** observed connection acceptance on the first request, first
  read attempt, parsed headers, body ready, queue enqueue/dequeue, handler start
  and handler finish. Observations made before trace extraction retain their
  original timestamps. Queue spans measure submission to the thread pool through
  entry into `process_client`, including any thread-pool lock acquisition.
  Keep-alive requests reset their observations; they do not inherit the previous
  request's acceptance time or trace context.
* **Puma response:** response preparation, body consumption and server write
  operations, including the supported sendfile/hijack paths until they return.
  The enclosing request finishes after Puma's body close and after-reply callbacks.
  A hijacked connection's later lifetime is outside this interval.
* **Controller:** `process_action` on both `ActionController::Base` and
  `ActionController::API`, including before/around/after callbacks, authorization,
  action execution and synchronous rendering. Exceptions retain their original
  behavior and are recorded on the controller span. Middleware and deferred body
  enumeration are outside the controller interval.

Puma events and controller/queue/request durations include monotonic elapsed
milliseconds. Cross-process span timestamps use each process's wall clock.
Neither handler entry nor a read attempt establishes packet arrival time. Kernel
listen backlog, work before Go's handler entry, and downstream receipt after a
write remain outside these measurements. The new spans do not by themselves
diagnose an earlier trace's blank interval.

## Configuration and builds

These environment switches default to enabled; set one to `false` and restart
the affected process to disable that layer:

| Variable | Layer |
| --- | --- |
| `IAM_TRACE_CONTROLLER_PHASES` | Controller spans |
| `IAM_TRACE_SERVER_PHASES` | Custom Puma spans/events |
| `IAM_TRACE_INGRESS_PHASES` | Thruster spans/events |
| `IAM_TRACE_HTTP_PHASES` | Existing custom Ruby HTTP phases |

These switches do not disable the existing automatic Rack/SQL/HTTP tracing.
Pass them to container environments through the appropriate Compose override.

Thruster uses the OpenTelemetry Go SDK and HTTP instrumentation with a bounded,
asynchronous batch exporter. It exports OTLP/HTTP to `OTEL_EXPORTER_OTLP_ENDPOINT`
(default `http://otel-collector:4318`); the Go exporter also supports
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`. Its service name is the Rails
`OTEL_SERVICE_NAME` override, or the image's `IAM_RAILS_SERVICE_NAME`, plus
`-ingress`. Incoming W3C trace context and sampling decisions are propagated to
Puma. Actor headers and authorization behavior are preserved. No timing header
from a caller is treated as trusted internal authorization.

Each Dockerfile builds its existing pinned Thruster version (0.1.14, or 0.1.15
for group-service) from a SHA-256-checked upstream archive. A small patch installs
the adapter at the existing handler and transport boundaries. The build runs
upstream and adapter tests, then copies only the static binary into the Rails
image; no Go toolchain is added to the runtime image. `go.mod` and `go.sum` pin
the adapter dependencies. Ruby hooks target Puma 6.6.x; an unsupported version
prints a warning and skips installation, requiring review on upgrade.

`bin/thrust` selects `/usr/local/bin/iam-thrust` when present. Outside the built
images it retains the original gem launcher; set `IAM_THRUSTER_BINARY` to a
locally built adapter binary to obtain ingress tracing there too. Direct requests
to Puma's published port 3000 naturally bypass Thruster; requests to container
port 80 traverse ingress.

The identical helper/adapter copies are deliberate: Rails services have isolated
Docker build contexts. `test/tracing_configuration_test.rb` checks for drift.
Use `./dc_dev`, `./dc_test` or `./dc_prod` for rebuild/restart operations.

## Validation

`test/integration/trace_server_integration.rb` runs real Puma keep-alive requests
through controller callbacks and response handling, asserting span parentage,
actor/body preservation, event boundaries, exceptions, the controller switch,
and absence of OpenTelemetry context errors. Run it using the installed image:

```sh
docker run --rm --entrypoint bundle -v "$PWD:/workspace:ro" \
  parent_account_id/user-management-service exec ruby \
  /workspace/test/integration/trace_server_integration.rb
```

The ingress adapter tests verify trace propagation, request/response preservation,
upstream phase events, unsampled parents and disabled tracing. They run during
each image build. Targeted `go test -race ./internal -run TestIAM` also passes.
The broader upstream race run exposes an existing race in
`internal/upstream_process_test.go`; the ordinary upstream suite passes.

These checks establish instrumentation correctness, not calibrated performance
overhead or reproduction of the earlier full benchmark.

### Verified runtime, 2026-09-11

All six images built successfully, including both pinned Thruster versions and
their ordinary upstream/adapter tests. Root regressions passed with 35 tests and
188 assertions; the real-Puma suite passed with 3 tests and 62 assertions.
The existing HTTP, Rack and GraphQL integration checks also passed. Puma 6.6.0
and 6.6.1 were exercised, and the final context test includes baggage preservation.

The seven web roles were restarted through `./dc_prod`, preserving `/can`, Redis
enabled where configured, batched retrieval and batch size 200. Every ingress
smoke request returned HTTP 200. Jaeger verified the complete parent chain,
per-role ingress/application identities, controller spans and upstream/Puma
events for all seven roles. There were no OpenTelemetry context/export errors
in the web-service logs after restart.

[The verification snapshot](../reports/summary/request-tracing-2026-09-11.json)
contains every trace ID and observed event list. The UI root request is trace
`1d1071cd678adf9f8b5ae913a9f31c08` (`FrontdoorController#index`, 10 spans), available
at the local Jaeger `/trace/1d1071cd678adf9f8b5ae913a9f31c08` path.
