# Authorization Context

Protected retrievals run under one explicit, immutable execution context:

```ruby
AuthorizationContext.as_requesting_user(user_id: actor_id, account_id: account_id) do
  Account.find(account_id)
end

AuthorizationContext.as_iam(originating_user_id: actor_id) do
  RelationshipFact.find(...)
end
```

`current!` raises `AuthorizationContext::MissingContextError` when no scope is
active. Scopes nest and always restore their predecessor. Capture a context
before starting deferred work and explicitly re-enter it with `with(captured)`;
thread and fiber locals are intentionally not assumed to propagate.

IAM means authenticated service authority. It does not turn an actor request
into a privileged request or replace capability checks. `originating_user_id`
keeps attribution when an authorization evaluator narrowly enters IAM scope.
Requests claiming IAM authority must also authenticate with the shared internal
token. The scope header alone is never trusted.

ActiveResource models become protected by inheriting from an application-owned
base that includes `AuthorizationContext::ActiveResourceProtection`. The base
guards the connection at each HTTP invocation and derives fresh transport
headers from the active context, avoiding class-header and pooled-connection
mutation. Custom Faraday/cache retrievals must call `current!` before reading
and use `transport_headers` for outbound metadata.

Protected local models include `AuthorizationContext::ActiveRecordProtection`
through their application-owned `ApplicationRecord`. It guards relations at
execution time, including `unscoped` and association relations. Protected
`load_async` is rejected because the current services do not propagate context
into Active Record's executor; use an explicitly captured context in deliberate
thread/job code or execute the relation synchronously inside the scope.
