# Production reseed preparation — 2026-09-13

The production Compose project is `gp`, operated through `./dc_prod`. The requested sequence was to truncate first, then migrate and deploy, leaving the seed publication for a later step.

## Reset and migration

All production application processes and seed workers were stopped before clearing data. All non-metadata public tables in the 20 PostgreSQL databases were truncated with identity sequences reset. Rails `schema_migrations` and `ar_internal_metadata` were preserved. Application tables in the four existing user-management production SQLite files were cleared as well.

The four dedicated production Redis instances were cleared. The production in-memory event broker was recreated to discard old seed events. The current application images were built after truncation, and `db:prepare` completed for all six applications. The authorization migration `20260914000000` created active group-owned grants and retained the empty legacy grant table. All five domain databases were checked for applied migrations and empty domain tables.

## Production configuration

- `prepare_prod.sh` now starts and checks all nine web services, including `group-auth-service` and `organization-auth-service`.
- The group and organization production Rails host allowlists include their authorization lookup hostnames. Deployment readiness checks send each service's actual Host header.
- Each of the two existing named worker services per queue has two production replicas, giving four instances per worker type and 20 total. This applies to organization, account, user, grants, and group creation. The production configuration checker rejects any total other than four per type.
- The deployed seeder's effective default was verified as 1,000,000 users without invoking `seed!`. The benchmark and reproduction commands no longer override that default with 2,000,000. Historical benchmark results remain historical.

## Validation

Production configuration tests passed: 12 tests, 32 assertions. Stack configuration tests passed: 1 test, 3 assertions. The resolved production configuration passed owner/database/queue checks. Shell syntax and diff whitespace checks passed.

Final live checks passed:

- All nine web processes passed readiness with their actual service Host headers.
- Organization capabilities returned an empty array through the deployed group membership lookup. The group membership and organization provider fact endpoints returned empty results.
- All five seed queues reported zero visible and in-flight messages before worker startup.
- All 20 workers were running the current owner images with zero restarts: four each for account, grants, groups, organization, and user creation.
- All five domain databases still had every migration applied and all domain tables empty after worker startup.

A probe for a nonexistent Account scope returned the existing HTTP 500 missing-organization-context error. Account inheritance/allow checks require the next seeded dataset; the empty-data checks do not establish those results. The full correctness gates must run after replay and queue drain.

No seed events were published and no benchmark was run. Workers are running and waiting for the next seed publication. Verification output is recorded in [production-reseed-preparation/verification.txt](production-reseed-preparation/verification.txt).
