# Authorized Resource

The gem supplies two entry points backed by the same policy evaluator,
execution-local operation state, authorization client, errors, and telemetry:

- `AuthorizedResource::Base` protects ActiveResource clients.
- `AuthorizedModel::Base` protects local Active Record models (the repository's
  persistence-backed ActiveModel implementation).

A concrete model must declare a read policy and either a modify policy or
`read_only!`:

```ruby
class User < AuthorizedResource::Base
  requires_read_capability "account.users.read",
    scope_type: "Account", target: :account_id, iam: %w[IAM_SYSTEM]
  read_only!(iam: %w[IAM_SYSTEM])
end

class Account < AuthorizedModel::Base
  requires_read_capability "account.read",
    scope_type: "Account", target: :id, iam: %w[IAM_SYSTEM]
  allows_iam_modify "IAM_SYSTEM"
end
```

`target:` may be an attribute name or a callable. It identifies the owning
authorization scope, not necessarily the resource ID. Repeated declarations are
alternatives for the same record; every returned record must satisfy at least
one alternative. Collections are evaluated with the authorization service's
batched capabilities endpoint, once per scope type, rather than once per row.

IAM identities are explicit model policy. Listing an identity in `iam:` permits
that operation to use the receiving service's authenticated IAM behavior; the
gem never converts a requesting-user context to IAM and never treats every IAM
identity as globally privileged. Originating-user metadata continues to come
from `AuthorizationContext`.

## Supported operations

The base protects `find`, `all`, `first`, `last`, `where`, reloads, existence
checks, class deletes, create/save/update/destroy, and ActiveResource custom
methods. Public methods that delegate internally share one logical operation,
one authorization evaluation, and one `authorized_resource.<Type>.<operation>`
span. Net::HTTP/Faraday instrumentation remains responsible for HTTP spans.

Semantic reads implemented with POST, batched endpoints, and application cache
lookups must use `authorized_read`; custom mutations use `authorized_modify`:

```ruby
def self.search(params)
  authorized_read("search") do
    response = connection.post("/users/search", params.to_json, headers)
    format.decode(response.body).map { |attrs| new(attrs) }
  end
end
```

Local model relations authorize materialized rows as one batch. `find`, normal
relations and associations therefore use the declared row policy. Aggregates
(`count`, `pluck`, `pick`, `ids`, and `exists?`) do not reveal their targets and
must be enclosed in `authorized_read(records: ...)`; configured IAM readers may
run them directly. `load_async` is intentionally unsupported unless the caller
adds explicit authorization-context propagation.

For a custom operation whose semantics are intentionally stricter than normal
row access, build a named requirement in the service and pass it to the shared
wrapper:

```ruby
account_read = OrganizationAccount.authorization_requirement(
  "account.read", scope_type: "Account", target: :account_id
)
OrganizationAccount.authorized_read("managed_accounts", requirements: [account_read]) do
  relation.to_a
end
```

This is service policy; the gem still owns evaluation, batching, context checks,
failure classification, and instrumentation.

Pass `records:` when the authorization target is known before execution, or
`result_records:` to extract records from a nonstandard result. The wrapper is
required around the cache as well as transport so cache hits cannot skip the
check. Shared caches may retain raw data; identity-filtered results must not be
shared.

Direct `connection` calls outside one of these operation scopes fail with
`UnsupportedOperationError`. Class-level POST/PUT/PATCH is intentionally
unsupported because its semantic authorization category and target are
ambiguous. Wrap each supported endpoint explicitly. Deferred work must capture
and restore `AuthorizationContext`; operation state is execution-local and is
not an identity store.

## Mutation targets

Creates authorize the intended parent/container from the new record. Updates
authorize both the scope snapshot captured when the record was read and the
current scope, so a boundary-moving update requires authority on both sides.
Deletes authorize the existing target. Client-provided ownership attributes
select the requested target but are not proof of authority; receiving services
must continue to authenticate and authorize every request.

## Failures and telemetry

The following remain distinct: `AuthorizationContext::MissingContextError`,
`PolicyConfigurationError`, `ReadOnlyError`, `AuthorizationDenied`,
`AuthorizationTransportError`, and ActiveResource transport exceptions.
Spans contain only bounded resource type, service host, logical operation,
scope types, batch size, and outcome. Actor IDs, authorization headers,
credentials, payloads, and scope IDs are not span attributes.

To add a resource, inherit directly from `AuthorizedResource::Base`, configure
its site/format, declare its owning-scope read policy, and explicitly declare
its modify policy or `read_only!`. To add a local model, inherit through the
service's `ApplicationRecord < AuthorizedModel::Base` and put the same explicit
policy declarations on every concrete class. Add wrappers only for custom
operations; do not add another service base class or call an ActiveResource
`connection` directly.
