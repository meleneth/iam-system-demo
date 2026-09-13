# Agent Instructions

## Docker Compose

Use the repository wrapper scripts for Compose operations:

- `./dc_dev` for the development stack
- `./dc_test` for the test stack
- `./dc_prod` for the production stack

Do not invoke `docker compose` directly for these stacks unless the user explicitly asks for raw Compose behavior. The wrapper scripts include the required env files and override files; bypassing them can start or recreate containers with the wrong configuration.

## IAM_SYSTEM

`IAM_SYSTEM` is load-bearing. It denotes an intra-IAM blessed request from part of the system, and those requests may bypass normal authorization checks to fetch internal data.

Never convert a request made as a real actor/user into an `IAM_SYSTEM` request to make an authorization problem go away. Doing that breaks the security model by changing an actor-scoped request into a trusted internal system request.

## Authorization Model Notes

This repository is not a complete production IAM implementation. The demo is proving that the query model collapses authorization correctly across services and cache modes.

MSP relationships link a provider account to a client **organization**, never directly to client account IDs. They add virtual account inheritance alongside physical parent_account_id inheritance. MSP accounts must never occur in client parent_account_id chains. Normal group-owned Account grants on the provider account or its ancestors reflect into managed client accounts; no special MSP permission is required.

The intended app-facing authorization proof is an authorization-service capabilities API:

- `GET /capabilities/Organization/:organization_id`
- `GET /capabilities/Account/:account_id`

Those endpoints should return arrays of string capability names. Organization capabilities are direct organization-scoped grants. Account capabilities include direct/cascaded group-owned account grants using the same physical and virtual ancestry semantics as `/can`. Group scope is also supported.

`/can` is still the internal service-to-service authorization workhorse. Keep it stable unless the task is explicitly changing that contract.

Grants belong to groups, never directly to users. Resolve explicit memberships through group-service. Do not create or require `msp.admin.users`; MSP access uses ordinary capabilities. Group capabilities combine exact Group grants with grants covering the group’s owning account.

When auth-service needs relationship facts to answer authorization questions, use a narrow `IAM_SYSTEM_AUTH` path for that specific auth-context lookup only. Do not make `IAM_SYSTEM_AUTH` a general replacement for `IAM_SYSTEM`.
