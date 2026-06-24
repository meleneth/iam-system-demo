# GraphQL, Redis, and Why This IAM Demo Stays Fast

This repository is built around a distributed IAM workload: a user-facing GraphQL layer sits on top of several Rails services, and the expensive part is not rendering JSON, it is turning a query into the smallest possible set of downstream lookups.

The performance strategy has three layers:

1. GraphQL batches field resolution in `user-management-service`.
2. `organization-service` caches the organization-to-account expansion in Redis.
3. `authorization-service` caches per-user grants in Redis and checks hierarchies with pipelined set membership lookups.

That combination turns a request that could have become many HTTP calls and many DB lookups into a small number of batched service calls plus cheap Redis reads.

## 1) The GraphQL entry point is already shaped for batching

The user-management service exposes the main GraphQL API in [`user-management-service/app/graphql/types/query_type.rb`](https://github.com/meleneth/iam-system-demo/blob/main/user-management-service/app/graphql/types/query_type.rb).

The important fields are:

- `account(id:, as:)`
- `accounts(ids:, as:)`
- `organization(id:, as:)`

The `accounts` field uses GraphQL-Ruby Dataloader:

```ruby
dataloader.with(Sources::AccountById, as: as, otel_ctx: otel_ctx)
  .load_all(ids)
  .then { |records| records.compact }
```

That matters because it allows the resolver to collapse many logical account fetches into one batched source call instead of one request per field.

The nested GraphQL types are also wired for batching:

- [`user-management-service/app/graphql/types/account_type.rb`](https://github.com/meleneth/iam-system-demo/blob/main/user-management-service/app/graphql/types/account_type.rb) loads `users`, `users_count`, and `groups_count` through dataloader sources.
- [`user-management-service/app/graphql/types/organization_type.rb`](https://github.com/meleneth/iam-system-demo/blob/main/user-management-service/app/graphql/types/organization_type.rb) loads `accounts` and `accounts_count`.

The query examples in [`graphql_queries.md`](https://github.com/meleneth/iam-system-demo/blob/main/graphql_queries.md) show the intended shape:

```graphql
{
  organization(
    id: "a7f2fa09-a480-4974-ab4b-f6c20e1f8a72"
    as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
  ) {
    id
    name
    accountsCount
    accounts {
      id
      name
      usersCount
      groupsCount
    }
  }
}
```

That is the key workload pattern: one organization request can fan out into many nested fields, so the system has to batch aggressively or the request cost explodes.

## 2) The organization service caches the expensive expansion

The organization service owns the organization/account relationship. Its hot path is [`organization-service/app/controllers/organization_accounts_controller.rb`](https://github.com/meleneth/iam-system-demo/blob/main/organization-service/app/controllers/organization_accounts_controller.rb), specifically `for_account`.

The sequence is:

1. Validate the caller identity from `pad-user-id`.
2. Check authorization for the requested `account_id` unless the caller is `IAM_SYSTEM`.
3. Resolve the `OrganizationAccount` rows for that account.
4. Load the organization record.
5. Look up `account_ids_by_organization:<organization_id>` in Redis.
6. On a miss, derive the account list from `organization.accounts.map(&:account_id)` and cache it for 300 seconds.

The relevant cache code is:

```ruby
cache_key = "account_ids_by_organization:#{organization_id}"
if cached = ORGANIZATION_CACHE.get(cache_key)
  results = JSON.parse(cached)
else
  results = organization.accounts.map(&:account_id)
  ORGANIZATION_CACHE.set(cache_key, results.to_json, ex: 300)
end
```

The Redis client is defined in [`organization-service/config/initializers/organization_cache.rb`](https://github.com/meleneth/iam-system-demo/blob/main/organization-service/config/initializers/organization_cache.rb).

### Why this helps

Without the cache, every request that needs an organization summary pays for the same membership expansion repeatedly.

With the cache:

- the organization-to-account mapping is computed once per 5 minute window,
- repeated GraphQL requests reuse the cached account list,
- the payload already includes the organization object, so the caller does not need a second request just to recover the organization name.

The service also exposes a DB-native count endpoint in [`organization-service/app/controllers/organizations/accounts_count_controller.rb`](https://github.com/meleneth/iam-system-demo/blob/main/organization-service/app/controllers/organizations/accounts_count_controller.rb), and the GraphQL layer consumes it through the `accounts_count` dataloader source. So the organization side gets both:

- Redis for repeated membership expansion,
- batch-friendly service calls for counts.

## 3) The authorization service caches grants as Redis sets

The authorization service uses Redis in a different way. It is not caching a single object response. It is caching a set of allowed scope IDs per user and permission.

The Redis client lives in [`authorization-service/config/initializers/authorization_cache.rb`](https://github.com/meleneth/iam-system-demo/blob/main/authorization-service/config/initializers/authorization_cache.rb).

The main logic is in [`authorization-service/lib/authorization/account_grant_checker.rb`](https://github.com/meleneth/iam-system-demo/blob/main/authorization-service/lib/authorization/account_grant_checker.rb).

### Cache fill on miss

`cached_user_grants(user_id, permission)` does a DB lookup only when the Redis set does not already exist:

```ruby
key = "user_grants:#{user_id}:#{permission}"
unless AUTHORIZATION_CACHE.exists?(key)
  scope_ids = CapabilityGrant.where(
    user_id: user_id,
    permission: permission,
    scope_type: "Account"
  ).pluck(:scope_id)
  AUTHORIZATION_CACHE.sadd(key, scope_ids) unless scope_ids.empty?
  AUTHORIZATION_CACHE.expire(key, 300)
end
```

That means the expensive relational query is paid once per TTL window, and the common case becomes set membership against Redis.

### Pipelined membership checks

The checker then evaluates many account IDs at once:

```ruby
values = @redis.pipelined do |pipe|
  account_ids.each { |id| pipe.sismember(@user_grants_key, id) }
end
```

That is a crucial optimization. Instead of one network round trip per account, the service sends a batch of membership checks in one Redis round trip.

### Hierarchy-aware pruning

`authorized_for_all?(hierarchies)` does not blindly walk every account in every hierarchy. It checks the current head of each hierarchy, drops the ones that are authorized, and only walks deeper into the hierarchies that still need to be resolved.

That makes the cost proportional to how quickly the system finds a match:

- if the user already has the right grant near the top, the check ends quickly,
- if not, the algorithm trims one level and retries only for the remaining paths.

The controller in [`authorization-service/app/controllers/can_controller.rb`](https://github.com/meleneth/iam-system-demo/blob/main/authorization-service/app/controllers/can_controller.rb) ties this to the account hierarchy lookup:

1. fetch the account hierarchy,
2. build the grant checker,
3. ask whether all requested scopes are authorized.

The `IAM_SYSTEM` header bypass is important too. Internal service-to-service flows can skip the permission check entirely when the request is already trusted.

## 4) How the pieces combine

The real speedup comes from the layers working together.

### Step 1: GraphQL batches the shape of the request

The user-management service resolves nested GraphQL fields through Dataloader sources instead of resolving each field independently.

That means:

- account lists are fetched in batches,
- user lists and group lists are fetched in batches,
- counts are requested through compact service endpoints.

### Step 2: Organization expansion is cached once

When the request needs an organization and its member accounts, `organization-service` returns both the organization object and the account IDs, and then caches the account ID list in Redis.

That avoids recomputing the same organization membership over and over.

### Step 3: Authorization becomes pipelined set membership

When the request needs authorization checks, `authorization-service` turns “does this user have permission on any of these hierarchical account scopes?” into a Redis set-membership problem.

That is a much cheaper shape than repeated DB reads:

- one DB fill on miss,
- one pipelined Redis call for many candidate IDs,
- hierarchy pruning to avoid unnecessary work.

### Combined effect

For a typical nested GraphQL request, the expensive parts shrink from:

- many service calls,
- many SQL queries,
- repeated hierarchy traversals,
- repeated permission checks,

to:

- a few batched GraphQL source fetches,
- one cached organization expansion,
- one cached authorization grant set,
- pipelined Redis membership checks.

That is why the system can handle deeply nested account/organization queries without the usual N+1 explosion.

## 5) What this does not claim

This is a fast design, but it is not magic.

- TTL-based caching is currently 300 seconds in the Redis-backed paths.
- Invalidation is not fully implemented.
- Some sources are batched better than others.
- For example, [`user-management-service/app/graphql/sources/accounts_with_parents_by_id.rb`](https://github.com/meleneth/iam-system-demo/blob/main/user-management-service/app/graphql/sources/accounts_with_parents_by_id.rb) still iterates per key, so it is less optimized than the fully chunked `AccountById` source.

So the performance story is strongest where the code actually uses:

- Dataloader batching,
- Redis set membership,
- cached organization membership expansion,
- and bounded authorization checks.

That is the practical architecture of the performance win.
