System Map

user-management-service: User Interface Layer
be able to look at organizations
be able to impersonate a user (view the user management screen as a particular user)
build the flat account cache layer

accounts have parent_account_id, which makes for bad times when querying - n+1 in effect

plan - flat account 'view'

gemify organization-service/lib/mel/filterable.rb

gemify ActiveResource models individually

Actually Do Soon:

add a same_org scoped support for organization_accounts/for/:account_id that saves from having to get the org id then ask again for the org accounts

MSP authorization redesign:

Current MSP dataset/model is invalid. MSP identity is organization-level, not account-level.

Decisions locked:
- Add app-facing authorization-service capability queries:
  - GET /capabilities/Organization/:organization_id
  - GET /capabilities/Account/:account_id
- Responses are arrays of string capability names only.
- MSP orgs link to client orgs. Client orgs must not expose which MSP manages them through normal caller-facing APIs.
- MSP operational cohorts are accounts inside the MSP organization.
- Client organizations link to an MSP cohort account.
- msp.* grants are visible only in MSP organization context.
- msp.admin.users is scoped to the MSP organization.
- Non-msp operational grants are scoped to MSP cohort accounts and reflect into accounts in linked client organizations.
- Account context never returns msp.* capabilities.
- Capability tests must include at least two MSP cohort accounts to prove isolation.
- Add direct client-account grant do.some.mcguffin in tests to prove direct target grants appear only in that target account context.
- Add IAM_SYSTEM_AUTH as a distinct auth-service-to-relationship-service identity, accepted only by the new auth context lookup endpoint.
- Keep route-level CRUD removal for simple scaffold resources; read routes are still useful.

Open questions:
- Exact relationship endpoint shape for batched auth-context lookup.
- Whether the auth-context relationship endpoint belongs in organization-service, account-service, or a narrow new service boundary.
- Exact schema/migration path from msp_managed_accounts to MSP org -> client org links, including cohort account.
- How Redis cache should represent org-level MSP capability expansion, and how no-cache SQL path stays semantically equivalent.
- Which existing MSP-specific public routes/GraphQL fields should be removed or hidden after the new capabilities endpoint exists.
- How demo_user_seeder should regenerate MSP fixtures around MSP orgs, cohort accounts, client orgs, and client accounts.
- Whether capability_grants should get a partial index for msp.* organization grants.
