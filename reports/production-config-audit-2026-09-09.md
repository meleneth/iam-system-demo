# Production configuration audit — 2026-09-09

Compared the effective JSON from `./dc_dev config --format json` and `./dc_prod config --format json`, plus shared worker definitions, Goaws queues/subscriptions, service Dockerfiles, and production preparation instructions. No production services were started for this audit.

## Findings fixed

- Production omitted `groups-create-service-worker-01` and `groups-create-service-worker-02`. Both are now included with `RAILS_ENV=production` and the group application's primary/cache/cable/queue database settings.
- Shared group workers advertised `groups_create`, but the subscription and worker code use `group_create`. The configured URL now matches. The current worker constructor uses its hardcoded default, so the typo was misleading configuration; the absent consumers caused the observed backlog.
- Group workers depended on authorization-service, despite writing to group-service's database. Their dependency now follows group-service and its database readiness dependencies, like the other worker definitions.
- Group and grants workers included literal quote characters in `SECRET_KEY_BASE`; these now match their owning applications.
- The benchmark plan's explicit start/stop commands omitted group workers. `seed_workers.sh` now discovers the complete worker list from the resolved stack, and the plan uses it for both operations.
- `prepare_prod.sh` and `seed_workers.sh prod start` now run `scripts/check_production_config.rb`. It checks dev service coverage, all five subscribed queues, consumer presence, worker images/dependencies/queue URLs, database and secret parity with owning applications, production Rails environments, and PostgreSQL connection settings against the target container configuration.

## Verified effective configuration

| Item | Development | Production |
| --- | --- | --- |
| Total services | 33 | 48 |
| Application services | 7 | 7 |
| Seed workers | 10 | 10 |
| PostgreSQL services | 5 | 20 |
| Redis services | 4 | 4 |
| Queue service | 1 | 1 |
| Telemetry/monitoring services | 6 | 6 |

Production now includes every development service. Its 15 additional services are cache, cable, and queue PostgreSQL databases for each of the five database-backed applications. Each of the five queues (`organization_create`, `account_create`, `user_create`, `grants_create`, `group_create`) has two production consumers.

All production Rails applications and workers resolve to production mode. Every worker uses its owning application's image, database URLs and secret. PostgreSQL hosts, database names, usernames and passwords match their target service definitions. Every internal API URL hostname resolves to a service in the Compose model; the images expose port 80 through Thruster. This is configuration validation, not a live connectivity test.

All 20 PostgreSQL bind mounts are under `data/production/`. UMS fixtures use `data/production/demo-fixtures`; SQLite uses the project-scoped `gp_user-management-storage` named volume. Development uses separate database bind mounts. No published-port collisions were found among 92 bindings across test, development and production.

## Remaining differences and limits

- Production defaults to batch size 1000; development defaults to 10000. The measured matrix deliberately overrides batch sizes and verifies runtime values.
- Development's workers and account-auth-service still inherit `RAILS_ENV=test` from shared definitions. Production overrides all of them to production. Development is therefore a topology reference, not an environment-settings template.
- Development supplies `GLOBAL_IAM_DEMO_USE_REDIS` to user-service; production does not. No consumer of that flag was found in user-service application/config code. The cache-owning services have their configured flags.
- Goaws advertises queue URLs using `us-east-1.eventstream-1`, which failed DNS lookup during the earlier diagnostic. Existing workers and the seeder instead use explicit `http://eventstream:4566/000000000000/...` URLs. This shared diagnostic/discovery issue was not changed in this audit; generic clients must not blindly reuse advertised URLs.
- Configuration checks cannot prove successful ingestion or runtime readiness. The cancelled run's database contents were dropped; the old on-disk fixture manifest is stale. Fresh preparation, seeding, queue-drain verification and live smoke gates are required before another measured collection.
- No authorization identities, `/can` behavior, or query semantics were changed.

## Validation

- Production configuration preflight: passed, 48 services.
- Cross-stack published-port check: passed, 92 bindings.
- Regression tests via a temporary `./dc_test run --rm --no-deps` container: 12 tests, 39 assertions, zero failures/errors. These include missing consumers (even when also absent in development), queue-name typos, wrong Rails environments, wrong databases, wrong dependencies, secret mismatches, and unmatched subscriptions.
- Shell syntax and `git diff --check`: passed.
- Final `docker ps`: no running containers. No seed or benchmark was restarted.
