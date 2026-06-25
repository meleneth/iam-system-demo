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
