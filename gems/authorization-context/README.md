# Authorization Context

Protected retrievals run under one explicit, immutable actor context:

```ruby
AuthorizationContext.as_requesting_user(user_id: actor_id) do
  Account.find(account_id)
end

AuthorizationContext.as_iam do
  RelationshipFact.find(...)
end
```

The context contains only `actor_id`, and service-to-service requests propagate
it only as `pad-user-id`. `IAM_SYSTEM` and `IAM_SYSTEM_AUTH` are reserved
actors used to exercise the demo's internal routing rules. They are not
authenticated identities or a security boundary.

`current!` raises `AuthorizationContext::MissingContextError` when no actor is
active. Scopes nest and always restore their predecessor. Capture a context
before starting deferred work and explicitly re-enter it with `with(captured)`;
thread and fiber locals are intentionally not assumed to propagate.

ActiveResource models become protected by inheriting directly from
`AuthorizedResource::Base`. AuthorizedResource requires and propagates the
actor context. It does not evaluate capabilities or re-authorize returned
records. The receiving service evaluates the forwarded actor according to the
demo's authorization model. The gem owns remote-operation instrumentation,
connection guards, and fresh per-request transport headers; this gem remains
the only actor-context store.

Protected local models inherit through each service's conventional
`ApplicationRecord < AuthorizedModel::Base`. `AuthorizedModel` owns model
policy, capability evaluation, relation/mutation enforcement, and operation
telemetry in the receiving service while this gem remains the single context
store. Protected `load_async` is rejected because the current services do not
propagate context into Active Record's executor.

## Development

The gem has an independent RSpec suite and does not require a service to boot:

```sh
bundle install
bundle exec rake
```
