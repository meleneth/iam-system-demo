# Authorized local prod rollout — 2026-09-13

The user subsequently authorized applying the repair to the repository's prod and dev stacks. This supersedes the earlier investigation's no-deployment status. Nothing was published externally.

## Prod completed

- Built all six application images from the repaired working tree and recreated their services, including account-auth-service, using `./dc_prod`.
- Stopped application services during migration/cache invalidation. Queue workers were already stopped and remain stopped; future organization workers use the rebuilt image.
- Preserved a complete pre-migration organization database dump locally as `prod-organization-before.dump` (excluded from Git).
- Applied migration `20260913000000`: archived three duplicate original rows, retained 1,240,824 memberships, and verified zero duplicate account IDs plus the unique account ownership index. See `prod-migration.log`, `prod-data-verification.txt`, and `prod-final-ownership.txt`.
- Cleared database 1 of the dedicated authcache, accountcache, orgcache, and groupcache Redis instances while application services were stopped. Recreating services also removed their process-local caches.
- Ran the live gate against the existing production fixture manifest: **26 checks passed**, including exact legitimate Account identities, foreign Account denials, mixed Organization batch denials, MSP owned-client allows, cross-MSP denials, repeated calls, and the branching fixture denial. See `prod-gate.json`.
- All seven application service containers were running at final verification; see `prod-final-services.txt`.

No prod reseed was performed. Historical benchmark evidence is unchanged. The gate is sampled correctness evidence, not full article-scale response validation; full performance reruns and article claims remain blocked as described in the parent report.

## Dev deferred by user

Dev was stopped at the start. Its configured PostgreSQL 18 organization database had no application tables; the old fixture manifest did not represent a populated current database. Started its infrastructure and repaired services, prepared the schema, and cleared the dedicated caches. The initial small seed attempt failed in artifact generation before publishing records (`dev-seed.log`). The retry command did not start. The user then deprioritized dev; no further seed or correctness gate was run. Dev services and idle seed workers remain running. The historical fixture manifest was preserved; the failed seed's partial artifacts are in a separate directory.
