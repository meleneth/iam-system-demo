# Authorized Resource

The gem supplies two deliberately different boundaries:

- `AuthorizedResource::Base` wraps remote ActiveResource operations.
- `AuthorizedModel::Base` protects records in the service that owns them.

**AuthorizedResource requires and propagates authorization context. It does not
evaluate capabilities or re-authorize returned records. The receiving service
authenticates the context and enforces authorization.**

## Remote resources

Remote models inherit directly from `AuthorizedResource::Base` and configure
only their normal ActiveResource transport:

```ruby
class User < AuthorizedResource::Base
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL")
  self.format = :json
end
```

Every protected operation requires an active `AuthorizationContext`. Missing
context raises `AuthorizationContext::MissingContextError` before cache access
or network I/O; the gem never supplies a default identity or enters IAM scope.
Requesting-user contexts propagate the actor and optional account/organization
metadata. IAM contexts propagate the explicitly selected IAM identity, its
internal authentication token, and any originating-user attribution. IAM still
follows the receiving service's existing service-authority rules.

The transport boundary derives fresh headers for every request. It never stores
identity in ActiveResource class headers or shared connection state. Nested
contexts, exception restoration, deferred-work capture/re-entry, and
thread/fiber isolation remain owned by the `authorization-context` gem.

`find`, `all`, `first`, `last`, `where`, `build`, reloads, existence checks,
pagination, create/save/update/destroy, and ActiveResource custom methods are
covered. The connection proxy also fails closed and propagates context for an
alternate direct connection call. Prefer a named wrapper for custom endpoints,
especially a POST whose meaning is a read:

```ruby
def self.search(params)
  authorized_read("search") do
    response = connection.post("/users/search", params.to_json, headers)
    format.decode(response.body).map { |attributes| new(attributes) }
  end
end
```

Use `authorized_modify("operation")` for custom mutations. Put cache lookup
inside the wrapper so a cache hit still requires context. Raw data may be
shared only when the receiving service independently authorizes every request;
identity- or scope-filtered results must retain their existing partitioning.

Ordinary resource operations make no client-side `/can` or `/capabilities`
request. A direct application call to those APIs remains an ordinary explicit
remote operation and is not altered by this abstraction.

## Receiving-service models

The receiving service declares and enforces capability policy through
`ApplicationRecord < AuthorizedModel::Base`:

```ruby
class User < ApplicationRecord
  requires_read_capability "account.users.read",
    scope_type: "Account", target: :account_id, iam: %w[IAM_SYSTEM]
  allows_iam_modify "IAM_SYSTEM"
end
```

`target:` identifies the real authorization target and may be an attribute or
callable. Repeated requirements are alternatives. `AuthorizedModel` batches
authorization evaluation across materialized collections, checks create
containers, checks old and new targets for boundary-moving updates, and checks
the existing target for deletes. Concrete server models require an explicit
read policy and either a modify policy or `read_only!`.

Relation materialization, associations, aggregates with explicit targets,
custom server queries, and mutation callbacks remain protected. Client-supplied
ownership fields select a requested target but never prove authority: the
receiving service authenticates propagated context and evaluates its own model
policy before returning or changing data.

## Telemetry and failures

Remote logical operations emit one
`authorized_resource.<Resource>.<operation>` span with bounded resource type,
service host, operation, collection size when available, and outcome. Automatic
Net::HTTP instrumentation owns HTTP spans; the gem only injects trace context
into fresh headers and does not emit duplicate HTTP spans. Actor IDs, scope IDs,
authorization headers, credentials, and payloads are not span attributes.

`authorized_resource.authorize` spans are emitted only by `AuthorizedModel` in
the receiving service. Their child authorization-service HTTP spans distinguish
permission evaluation from resource transport. Remote transport errors keep
their ActiveResource exception types, and missing context remains distinct from
server denial and authorization-service transport failures.

To add a protected remote resource, inherit from `AuthorizedResource::Base`,
configure its site/format/path, and wrap only nonstandard endpoints or caches
with a semantic operation name. Do not declare capabilities on the remote
model. Add the capability requirement to the owning service's
`AuthorizedModel` and test it through the real transport boundary.
