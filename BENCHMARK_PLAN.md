> **2026-09-13: publication blocked by confirmed authorization failures.** Historical results below are preserved, but do not establish correct isolation or performance of the repaired program. See the [investigation, regressions and rerun requirements](reports/authorization-correctness/README.md).

# Article evidence collection plan

Current reseed default: 1,000,000 users, with four production instances per seed worker type (20 total). The commands below use the seeder default; set `USER_COUNT` explicitly only to override it.

Historical run, superseded by the [production reset](reports/production-reseed-preparation.md): seeding completed on 2026-09-10 at 10:42 UTC:
2,000,000 jobs, all five seed queues drained, and all ten seed workers stopped.
Elapsed seed time including queue drain was 27,212.111 seconds (7h 33m 32s).
The fresh production manifest replaces the stale manifest from the cancelled run.
Preparation passed production HTTP readiness for all seven web services after
updating net-imap to 0.6.7 for Ruby 4 production eager loading.

Seed logs, CPU/RAM details, and preparation evidence are in
`reports/raw/article-no-x-20260910T011818Z/`. Collection has not yet passed its
live smoke gates. Run from multiuser/no-X mode; both smoke gates must pass before
measured cases.

## What this run covers

The runnable matrix is [`benchmarks/article_matrix.json`](benchmarks/article_matrix.json).
The launcher is [`collect_article_evidence.sh`](collect_article_evidence.sh).
It runs cases sequentially, with no competing benchmark clients or seed workers.
It starts only the required databases, caches, telemetry, and application services.
Stop any separately running seed workers or other benchmark jobs before starting.

| Case group | Comparison / workload | Settings held constant |
| --- | --- | --- |
| Smoke gates | Depth 1/5 hierarchy comparisons; full deep-chain organization | Real fixture actor, `/can`, Redis off, batch 1000, one repetition |
| CTE | Parent-by-parent GET versus one hierarchy GET, depths 1/5/10/25 | Identical targets and actor, `/can`, Redis off |
| Smart APIs | Individual hierarchy GETs versus JSON POST batches | Same target set and actor; deep chain: 1/8/25 targets, wide org: 1/8/251 targets |
| Hierarchy cache | Repeat hierarchy comparisons cold and warm | Same targets, actor, `/can`, batch 1000 |
| Retrieval | Serial versus batched, deep and wide organizations | Same actor, capabilities mode, Redis off, batch 1000 |
| Authorization | Capabilities versus `/can`, wide and sparse organizations | Batched retrieval, same actor, Redis off, batch 1000 |
| Application cache | Wide and dense organization partitions, cold versus warm | `/can`, batched retrieval, batch 1000 |
| GraphQL scale | Deep, wide, dense, MSP 10k/50k/100k | `/can`, batch 10000; Redis disabled and independently cold/warm |
| GraphQL chunk boundaries | Batch 200 versus 1000 versus 10000 | `/can`, same deep/wide/dense and MSP 10k queries, cold/warm |

There are 17 launcher cases. Each measured case has three repetitions per
applicable mode/phase. The hierarchy driver alternates mode order between
repetitions. Three repetitions support descriptive median/range comparisons;
**do not publish p95/p99 or saturation-throughput claims from this matrix**.
GraphQL Account concurrency stays fixed at four workers. No server-model or
concurrent-client comparison is implied.

The 25-level fixture has 25 accounts and 500 users; the wide fixture has 251
accounts and 5,020 users; dense has one account and 20,000 users; sparse has 401
accounts and 8,020 users. MSP fixtures span many client organizations and are
reported separately from single-organization growth.

The CTE comparison measures actor-authorized end-to-end requests. It includes
organization membership and authorization work; it is **not isolated SQL execution
time**. Part 5 also includes the authorization-call reduction produced by a batch
API. Returned IDs and parent links are checked against the fixture in both modes.
Actor identity is never changed to IAM_SYSTEM to obtain a successful sample.

## Production preparation (before the measured run)

Grafana now uses a project-specific named volume; existing bind-mounted test
Grafana data remains on disk but is no longer used by the stack.

The launcher and both drivers default to `BENCHMARK_STACK=prod`, use `./dc_prod`
(project `gp`), and read ports from `production.env`. The app is on port 7501,
account-service on 11360, and Jaeger on 11290. Every measured application must
report `RAILS_ENV=production`; the launcher checks this before sending samples.
For a deliberate development run, set `BENCHMARK_STACK=dev` and use a separate
collection directory. Never point a production run at the development manifest.

Production has separate databases and initially has no article fixtures. Prepare
its schemas and applications without resetting any existing data:

### Limited seed for trace inspection

`DEMO_SEED_PROFILE=limited` seeds exactly 15,526 users: `deep_chain` (500),
`wide_org` (5,020), `massive_fanout_10k` (10,000), and `trace_isolation_msp` (6).
It preserves the full dataset's shared fixture IDs and adds a second independent
MSP for the trace runner's authorization gate. It publishes no random filler and
rejects a nonzero `USER_COUNT` or `DEMO_SKIP_FIXTURES=1`.

After preparing production with `./prepare_prod.sh`:

```bash
./seed_workers.sh prod start
./dc_prod run --rm --no-deps -T -e DEMO_SEED_PROFILE=limited user-management-service bin/rails runner scripts/demo_user_seeder.rb
./seed_workers.sh prod stop
ruby scripts/refresh_article_traces.rb
```

The seeder writes the normal manifest and examples under
`data/production/demo-fixtures/latest`. The trace runner uses that manifest,
checks authorization boundaries, warms each profile, and saves 13 source traces
from seven configurations. It does not run the full benchmark matrix. These
traces establish request behavior on the limited dataset, not full-dataset timings.
Production Jaeger is at <http://localhost:11290>.
User-management GraphQL request spans are named `GraphQL` (or `GraphQL <operationName>`)
and include the submitted query text in the `graphql.document` tag. Expand the
request span's tags in Jaeger to inspect the query alongside its downstream calls.
Record-loading server spans and their calling HTTP spans show actual returned
counts, such as `Load 20 users`. Authorization calls identify the permission and
scope count. Cache tracing retains one `Redis pipeline: N GET` (or mixed-command)
span per real pipeline, with command counts but no key/value lists. Individual
Redis commands and application cache bookkeeping do not create spans; application
SQL on cache misses remains visible.

The default `DEMO_SEED_PROFILE=full` retains the normal 1,000,000-user seed.

### Full seed

```bash
./prepare_prod.sh
./seed_workers.sh prod start
set -o pipefail
mkdir -p reports/raw
./dc_prod run --rm --no-deps -T -e DEMO_PROGRESS_INTERVAL=10000 user-management-service bin/rails runner scripts/demo_user_seeder.rb 2>&1 | tee "reports/raw/seeding-$(date -u +%Y%m%dT%H%M%SZ).log"
./seed_workers.sh prod stop
```

`./seed_workers.sh prod start` first checks production/dev service parity, queue
consumer coverage, and production database settings, then discovers all seed
workers from the resolved production configuration. `stop` stops that same set.

Run this command in the attached host tmux pane: its output belongs to the
one-off runner, so following the long-running web service's logs will not show
seed progress. `tee` keeps both live output and a saved log; `pipefail` preserves
runner failures. The seeder flushes stdout immediately and reports at least every
five seconds while jobs are being published, as well as every 10,000 jobs.
This is progress reporting after successful publishes, not a heartbeat during a
blocked network request. Queue waits report every five seconds after polling.
Its first message is `Building fixture payloads...`, after Rails has booted;
silence before that message is outside the publishing loop.

Run seeding once, only when preparing the dataset. The seeder waits for queues to
drain and writes `data/production/demo-fixtures/latest/fixture_manifest.json`.
The measured launcher does not seed. It starts all 20 production PostgreSQL
services and runs `./analyze_databases.sh prod` before collection; the earlier
development ANALYZE does not apply to production. UMS keeps its production SQLite
storage in a persistent volume. Tests continue to run through `./dc_test`.

`ruby scripts/check_stack_ports.rb` resolves all three Compose stacks and rejects
conflicting published ports, including wildcard host bindings. All three stacks
can coexist; stop unrelated workloads for clean benchmark measurements.

## Run from multiuser/no-X mode

Save work before leaving the graphical session. From a text console, switch modes
using your normal host procedure, then start a tmux session so collection can
survive a terminal disconnect:

```bash
cd ~/code/iam-system-demo
tmux new -s iam-article
export BENCHMARK_STACK=prod
export COLLECTION_DIR="$PWD/reports/raw/article-no-x-$(date -u +%Y%m%dT%H%M%SZ)"
printf '%s\n' "$COLLECTION_DIR" > /tmp/iam-article-collection-path
set -o pipefail
./collect_article_evidence.sh 2>&1 | tee /tmp/iam-article-launch.log
```

Detach with Ctrl-B, D. Reattach with `tmux attach -t iam-article`. The launcher
prints the active case. `attempt-*/run.log` contains that driver's progress.
No browser, X session, or Grafana UI is needed. Docker access must already work
for your console user; avoid running the whole collection with sudo, which would
make its output root-owned.

Before a full run, preview without starting services:

```bash
./collect_article_evidence.sh --plan
```

To run only the two live smoke gates first, while keeping the same collection:

```bash
CASE_IDS=smoke-hierarchies,smoke-organization ./collect_article_evidence.sh
# Inspect results, then run the remaining cases:
SKIP_BUILD=1 ./collect_article_evidence.sh
```

Only use `SKIP_BUILD=1` after building this exact revision with the launcher.
The default invocation builds the six application images, starts infrastructure,
runs database ANALYZE, and recreates application services for each case's settings.
It waits for readiness and verifies running batch/auth/cache/retrieval settings.
Application images, process IDs and non-secret runtime settings are captured.

The default manifest is
`data/production/demo-fixtures/latest/fixture_manifest.json`; override `MANIFEST`
only deliberately. Queue count reaching zero remains sufficient seed readiness.
No reseeding or database reconciliation is part of this run. ANALYZE updates
planner statistics outside measured requests. Source revision, matrix and manifest
hashes must remain unchanged throughout a collection.

## Isolation, failures and timing

- Redis caches use **database 1**. Cold samples flush DB 1 in accountcache,
  authcache, orgcache and groupcache before each complete workload. No flush occurs
  between continuation pages. Redis-off cases make one measured phase per run.
- Warm samples receive a separate priming request/walk immediately beforehand.
  Do not mix prime rows into measured results. Cold means cold derived-result
  caches, not cold PostgreSQL buffer caches or newly started Ruby processes.
- Every organization/MSP walk follows continuations. Archive all pages; do not
  present one page as the complete organization.
- Serial retrieval has a 180-second **per-request** deadline; other requests use
  600 seconds. Hierarchy comparisons use a 600-second sample budget under the
  launcher. Keep timeout observations censored at the applicable bound. Whole
  multi-page walks can exceed one request's deadline.
- Non-smoke failures are retained as observations; the suite continues to later
  cases and `completed.json` records `success: false`. A completed suite is not a
  claim that every case succeeded. The final `collection_status.json` lists failed
  cases and the launcher exits nonzero if any remain. HTTP, GraphQL, equivalence and missing-trace
  failures must be classified separately before article use.
- Smoke failure stops the suite. Investigate it before continuing. A deployment,
  authorization or telemetry failure is not useful performance evidence.
- Trace polling is outside measured requests and continuation walks. Each
  hierarchy sample shares one trace ID across its direct HTTP requests; initiating
  context is external to the services. Other benchmark requests have individual
  trace IDs, linked from their result sidecars.
- Exporting large paginated workloads can take substantial time. Allow an extended
  unattended window rather than assuming a fixed completion time. The launcher
  never changes timeouts or silently reduces cardinality to make a case pass.

## Stop, resume and retry

Use Ctrl-C in the attached tmux session to interrupt a run. Confirm the child
benchmark process has exited before restarting. Do not stop databases or clear
caches underneath another active sample.

```bash
export COLLECTION_DIR="$(cat /tmp/iam-article-collection-path)"
SKIP_BUILD=1 ./collect_article_evidence.sh
```

Completed cases are skipped. Interrupted cases get a new `attempt-NNN` directory;
previous bodies, traces and logs remain intact. A collection lock prevents two
launchers using the same directory concurrently. Do not run separate collections
against the same stack simultaneously.

To retry recorded failures without deleting evidence:

```bash
RETRY_FAILED=1 SKIP_BUILD=1 ./collect_article_evidence.sh
```

Use `CASE_IDS=id1,id2` to target a subset. A changed source revision, fixture or
matrix requires a **new** `COLLECTION_DIR`; never merge unlike configurations into
one labeled comparison. The launcher leaves the final profile running for
inspection. Restore normal development settings afterward with `./dc_prod up -d`
from a shell without benchmark environment overrides.

## Artifacts and analysis

Raw artifacts are excluded from Git under `reports/raw/`; preserve this directory
on disk and back it up before changing datasets or cleaning the workspace.

```text
collection.json                 revision, input hashes, CPU/memory/session details
matrix.json                     exact requested case matrix
fixture_manifest.json           copied fixture identities
build.log / startup.log / analyze.log
<case>/completed.json            final attempt and success/failure
<case>/attempt-NNN/
  runtime.json / images.json     actual service configuration and images
  startup.log / run.log / status.json
  timings.csv / metadata.json
  response bodies and result JSON
  traces/*.json                  main-harness Jaeger JSON and status files
  <hierarchy-sample>/             driver result, requests, responses, trace JSON
```

Before article publication, summarize paired successful observations by fixture,
actor, mode, cache phase and batch size. Report median and range, bytes, outcome,
request counts and trace IDs. Preserve failures separately. Count HTTP server
spans by service and distinguish them from client spans. Label database/Redis
span counts as instrumentation counts unless verified to correspond one-to-one
with physical queries/commands/round trips. Settled trace counts and parent links
are useful checks, not proof that no spans were dropped.

The million-user generation article still needs preserved ingestion-duration,
worker and resource evidence from a generation run. This read-only collection
cannot recover those historical measurements. LocalStack/Goaws comparison claims
also require independent historical evidence or a separately approved experiment.
No data regeneration, worker scaling or queue-product comparison is included here.
