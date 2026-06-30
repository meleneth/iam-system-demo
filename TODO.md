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
- The auth-context relationship endpoint belongs in organization-service.
- Relationship table shape:
  - msp_managed_organizations
  - msp_organization_id
  - msp_account_id
  - client_organization_id
- client_organization_id is unique; a client org has at most one MSP relationship in this demo model.
- One MSP org can have many MSP accounts/cohorts.
- One MSP account/cohort can manage many client orgs.
- msp_account_id must belong to msp_organization_id through organization_accounts.
- client_organization_id must contain the target account through organization_accounts.
- Parent traversal for managed target accounts is constrained to the client organization's account set.
- MSP reflection is target-hierarchy based for pathological coverage, but a non-msp account grant on the MSP account is a broad hammer for every valid target account in that managed context.
- Normal account parent-chain collapse uses the existing account-service parent hierarchy API.
- The organization-service IAM_SYSTEM_AUTH endpoint handles MSP/client-org context.
- Auth-context endpoint shape:
  - POST /internal/auth/account_contexts
  - Header: pad-user-id: IAM_SYSTEM_AUTH
  - Body contains contexts with msp_organization_id, msp_account_id, and account parent lines supplied by auth-service.
  - Response returns only valid matched account contexts; out-of-context records are omitted rather than returned as denials.
- /can remains the internal service-to-service authorization workhorse.
- /capabilities does not support System scope; no system capabilities are currently defined.
- Remove old account-level MSP reflected route/plumbing instead of preserving compatibility.
- Remove pad-msp-account-id support paths when replacing the broken account-level MSP model.
- Cache final capability arrays for 5 minutes by user_id, scope_type, and scope_id.
- Redis-disabled mode computes from SQL plus live organization-service relationship facts; auth-service does not keep a second SQL projection of MSP relationships.
- Demo dataset can use one MSP cohort; tests must prove multi-cohort isolation.

Open questions:
- Exact schema/migration path from msp_managed_accounts to MSP org -> client org links, including cohort account.
- How Redis cache should represent org-level MSP capability expansion, and how no-cache SQL path stays semantically equivalent.
- Which existing MSP-specific public routes/GraphQL fields should be removed or hidden after the new capabilities endpoint exists.
- How demo_user_seeder should regenerate MSP fixtures around MSP orgs, cohort accounts, client orgs, and client accounts.
- Whether capability_grants should get a partial index for msp.* organization grants.
- Whether to repair group-service's missing spec helper as a separate test-harness cleanup.
