# Request tracing and warmed measurements

The traces retain cross-service **HTTP client and API server spans**, application
SQL, Redis commands/pipelines, cache operations, authorization computations, and
GraphQL/Dataloader operations. All six Rails services share this configuration;
the account-auth role exports a separate service identity.

Net::HTTP instrumentation records actual requests from Net::HTTP, Faraday, and
ActiveResource, including URL/method and response status. Rack instrumentation
extracts trace context and records each API call. It injects no actor identity;
existing actor headers and authorization semantics are unchanged. Typical ancestry:

```text
API server request
└─ application/authorization operation
   └─ HTTP client request (direct, Faraday, or ActiveResource)
      └─ downstream API server request
         └─ SQL query / Redis pipeline
```

Controller/action, custom connection/write/header/body phases, Rack response
lifecycle phases, serialization, and materialization timings remain removed.
HTTP request spans are intentional; no gallery-side span filtering is used.

## SQL and caches

`ApplicationSqlTracing` records executed application queries from
`sql.active_record`, with the actual SQL statement and notification duration.
It excludes Rails `SCHEMA`/`TRANSACTION` notifications, catalog introspection,
connection `SET`/setup commands, and cached results. PG and automatic ActiveRecord
object-operation instrumentation are disabled to avoid duplicate queries and
object-construction timings.

**ActiveRecord's per-request query cache remains enabled.** A query-cache hit
is not a PostgreSQL execution and therefore does not create a SQL span. The
unused Solid Cache gem, store configuration, and schema are removed; production
`Rails.cache` uses `NullStore`. Existing cache database volumes are not deleted.
Application-owned Redis caches are unchanged.

Organization cache fetch spans include hit/miss events. Redis lookups and cache
miss database loads remain visible; decoding has no separate timing span.

## Collection protocol

Commit runtime and collector changes, then run `scripts/refresh_article_traces.rb`.
It rebuilds through the selected repository Compose wrapper, unless explicitly
using already rebuilt images with `SKIP_BUILD=1`.

Each environment profile is started once and receives two workload
warmup passes before measurements. Warmup results are recorded separately; organization/GraphQL warmup traces are
also archived to verify that the preceding work settled.
Warmups settle before measurements, including when an enclosing request fails.
Puma PIDs and process start ticks are checked before/after warmup and after the
measured requests; a process change invalidates the warmed measurement.

For Redis profiles, the warmup exercises misses and hits. **Only Redis DB 1 is
flushed for the measured cold sample.** Rails is not restarted between warmup,
cold Redis, and warm Redis requests. PostgreSQL is not restarted, flushed, or
otherwise made cold. Existing infrastructure uses `--no-recreate`.

The harness records HTTP outcomes and client elapsed seconds separately from
trace envelopes. Failed requests remain failures. These showcase examples do not
replace historical benchmark-matrix measurements.

## Validation

`test/tracing_configuration_test.rb` checks the shared configuration and cache
policy. `test/article_trace_refresh_test.rb` checks warmup/flush ordering and
process continuity. Integration probes under `test/integration/trace_*` verify
real Net::HTTP/Faraday/ActiveResource calls, API parentage, actor/body/baggage,
exceptions, context cleanup, Dataloader ancestry, and SQL filtering with the
ActiveRecord query cache still enabled.

`scripts/validate_reduced_traces.py COLLECTION_DIR` validates source exports for
HTTP/API ancestry, SQL within API calls, cache visibility, and absence of
controller/phase/serialization/schema/setup spans.

Use `./dc_dev`, `./dc_test`, or `./dc_prod` for Compose operations. Historical
collections retain their original instrumentation and warmup limitations.
