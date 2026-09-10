# Stable container image update — 2026-09-09

All active external Compose image pins, application Dockerfile bases, Rails builder base, Ruby version files and active CI PostgreSQL image references were audited. Local application image names remain local build outputs. Commented Kamal accessory examples are not deployed services. The Dockerfile frontend remains on its stable `docker/dockerfile:1` channel.

| Project | Previous | Selected stable release | Source |
| --- | --- | --- | --- |
| Ruby | 3.4.4 | 4.0.6 (slim-trixie applications; trixie builder) | [Ruby releases](https://www.ruby-lang.org/en/downloads/releases/), [official image](https://hub.docker.com/_/ruby) |
| PostgreSQL | 17.5-bookworm | 18.6-trixie | [release notes](https://www.postgresql.org/docs/release/), [official image](https://hub.docker.com/_/postgres) |
| Redis | 8.0.2-bookworm | 8.10.1-trixie | [release](https://github.com/redis/redis/releases/tag/8.10.1), [official image](https://hub.docker.com/_/redis) |
| Grafana | 13.1.0 | 13.2.1 | [release](https://github.com/grafana/grafana/releases/tag/v13.2.1) |
| Loki | 3.7.3 | 3.7.7 | [release](https://github.com/grafana/loki/releases/tag/v3.7.7) |
| Promtail | 3.6.8 | 3.6.11 | [registry tags](https://hub.docker.com/r/grafana/promtail/tags) |
| Prometheus | 3.5.4 | 3.14.0 | [release](https://github.com/prometheus/prometheus/releases/tag/v3.14.0) |
| Jaeger | 2.19.0 | 2.20.0 | [release](https://github.com/jaegertracing/jaeger/releases/tag/v2.20.0) |
| OpenTelemetry Collector Contrib | 0.155.0 | 0.160.0 | [release](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.160.0) |
| Goaws | 0.5.3 | 0.5.4 | [release](https://github.com/Admiral-Piett/goaws/releases/tag/v0.5.4), [registry tags](https://hub.docker.com/r/admiralpiett/goaws/tags) |

No alpha, beta, release-candidate, preview or nightly versions were selected. Promtail's registry publishes 3.6.11 after its announced [end of life](https://grafana.com/docs/loki/latest/send-data/promtail/); the version update retains the existing project rather than migrating the log pipeline to Alloy. Collector and Goaws use their normal upstream 0.x release numbering; their selected GitHub releases are not marked prerelease.

## PostgreSQL 18 storage

PostgreSQL 18's official image uses `/var/lib/postgresql/18/docker` and declares its volume at `/var/lib/postgresql`. All 20 shared database definitions now mount `${..._POSTGRES_DATA}/pg18` at that parent location. This gives each stack fresh, separate PG18 storage while preserving its existing PG17 files. **Existing development/test data is not migrated into these fresh clusters.** Restoring old data requires a dump/restore or pg_upgrade; pointing PG18 directly at a PG17 cluster is not supported.

The resolved production configuration has 20 correct PG18 mounts; development and test each have five. No database files were moved or deleted during this update. The previously cancelled production fixture manifest remains stale; fresh fixtures are required before benchmark collection.

## Ruby 4 dependency compatibility

The first build rejected the old transitive Minitest 5.25.5 dependency because its gemspec excludes Ruby 4. The locked entry was updated to 5.27.0; no direct Minitest dependency was added. Native Nokogiri binaries were updated from 1.18.8 to 1.19.4, unicode-emoji from 4.0.4 to 4.2.0, and UMS SQLite binaries to 2.9.6. UMS also needed sexp_processor 4.17.5, ruby_parser 3.22.0 and google-protobuf 4.36.1 (with its Rake dependency). Bundler is aligned with the Ruby image's 4.0.16. Existing RSpec application suites remain the validation target; no testing-framework migration is part of this update.

## Validation

Validation results:

- Production preflight passes with 48 services; port validation passes with 92 bindings across all stacks.
- Resolved PG18 mount validation passes for production's 20 databases and dev/test's five each.
- All six application images built successfully on Ruby 4.0.6. All six booted Rails through `./dc_test run --rm --no-deps`, with telemetry disabled for the smoke check. UMS explicitly used `RAILS_ENV=test`.
- The rebuilt account image loads RSpec; its database-independent cache suite passed: 7 examples, 0 failures.
- UMS recovered from an upstream 504 fetching `tailwindcss-ruby-4.1.11-x86_64-linux-gnu.gem` and completed its build. Goaws downloaded successfully. The optional Rails builder and remaining infrastructure pulls encountered stalled large downloads; their stalled attempts were cancelled. Those images and the database-backed RSpec suites remain unvalidated because the required downloads did not complete.
- The Google mirror's PostgreSQL amd64 digest was independently compared with Docker Hub's tag metadata and matched (`sha256:7341002d2b8c7c5bdd7542a671a95b36196c0b5b888daf454ae4fc33ba5346d7`). A bounded 180-second retry also timed out (exit 124); no mirror image was relabeled.
- No IAM stack or seed was restarted. Eleven host cache/DNS/registry containers are running. Both RubyGems gem metadata and the registry cache returned HTTP 200 after restart; the Framework LED service is inactive.

Build, pull and test logs are preserved in `reports/raw/image-update-20260909/`; `release-evidence.json` records upstream release and registry metadata without credentials. Initial registry failures were caused by stopped host cache services. The DNS, registry and package-cache containers were restarted at the user's request. The Framework LED animation user service was stopped separately at the user's request.

## Production follow-up — 2026-09-10

Production eager loading exposed a net-imap 0.5.9 Ruby 4 Ractor::IsolationError
that the earlier test-mode boot probes missed. All six lockfiles now use 0.6.7;
all six images rebuilt and all seven production web services passed HTTP
readiness. Preparation removes production orphans and prints logs immediately
when a service exits. The old ad hoc group-worker orphan was removed.

PostgreSQL, Redis, Jaeger and Collector image downloads subsequently completed.
All 20 production PostgreSQL databases and four Redis caches started healthy.
Production seeding completed 2,000,000 jobs in 27,212.111 seconds including queue
drain, finished at 2026-09-10T10:42:10Z, and stopped all ten workers successfully.
The production fixture manifest is now fresh. Evidence and hardware details are
in `reports/raw/article-no-x-20260910T011818Z/`. Earlier download and validation
limitations above describe the initial update attempt, not this successful
production preparation. Full database-backed RSpec suites have not been run.
