# Authorization contract

This contract defines the model used by the code, seeded data, benchmarks, and article.

## Terms

* **User:** An identity requesting access to an object or action.
* **Organization:** A customer or provider boundary containing accounts.
* **Account:** A scope for resources and permissions. Accounts form a hierarchy through parent–child relationships via parent_account_id on the Accounts table.
* **Group:** A collection of users to which permissions can be granted.
* **Membership:** The relationship establishing that a user belongs to a group.
* **Capability:** A permission to perform a particular action.
* **Grant:** An assignment of a capability to a group within a specified scope (currently Account, Group, or Organization).
* **Scope:** The account, organization, or other explicitly identified boundary where a grant applies.
* **MSP:** Managed service provider—a provider managing access across client organizations. Its provider account is a virtual ancestor through an explicit relationship to the client organization. MSP accounts never occur in a client’s parent_account_id chain or returned hierarchy.
* **Target:** The object against which an action is requested.
* **Account hierarchy:** An account and its chain of parents. An ancestor is an account above it; a descendant is an account below it.

## Service Headers

* **IAM_SYSTEM** used for internal IAM requests that are explicitly not permission checked.  In an actual implementation, this would be implemented at least by request signing with a key that non IAM services are forbidden from knowing
* **IAM_SYSTEM_AUTH** is restricted to explicit authorization-context endpoints for group memberships, group ownership and MSP organization relationships. It cannot bypass ordinary resource endpoints.
* **HTTP_PAD_USER_ID** used to identify the user id the request is being made on behalf of 

## Rules

1. **Services own their data.** User service owns users; group service owns groups and memberships; account and organization services own their objects and relationships; authorization service owns grants and permission decisions.

2. **Users receive capabilities through groups.** Authorization service asks group service for the user’s applicable memberships when checking access to an account.

3. **An allow decision requires a matching grant.** The user must belong to the grant’s group, the grant must include the requested capability, and its scope must cover the target. Without such a grant, access is denied. Grants are additive.

4. **Account grants apply downward.** A grant covers its account and descendants, including across a provider-to-client organization relationship. MSP reflection is additional to physical parent_account_id inheritance: a grant on the linked provider account or its ancestors covers the managed client organization’s accounts. It does not cover ancestors or sibling branches. Organization grants cover exactly that organization. Group grants cover exactly that group; account grants also cover groups owned by covered accounts. group.read permits reading the group and its membership rows; account.users.read also permits those reads.

5. **MSP access follows grants.** Provider affiliation alone confers no access to client objects. Ordinary account capabilities control MSP access; there is no msp.admin.users capability or separate MSP role gate.

6. **Authorization uses the target’s actual scope.** This applies to objects requested by ID and to each protected object included in a composite response.

7. **Client hierarchies exclude the provider account.** The returned hierarchy stops at the client root. Internal authorization combines client ancestry with provider ancestry through the organization relationship.

8. **Optimizations preserve results.** Individual, batched, cached, and paginated execution must produce the same permission decisions and authorized objects.

9. **Evaluation uses fixed data.** Mutation handling and cache invalidation are outside this project. Memberships and grants remain explicit relationships that could be removed.

## Validation

A small, hand-verifiable dataset records expected permission decisions and returned hierarchies. It covers direct and inherited access, different group memberships, unrelated accounts, and provider/client boundaries.

Once the implementations agree with those expectations, rebuild the full dataset and run correctness gates before collecting benchmark results.
