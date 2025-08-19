# app/graphql/resolvers/account_with_parents_resolver.rb
module Resolvers
  class AccountWithParentsResolver < GraphQL::Schema::Resolver
    type [Types::AccountType], null: false

    argument :id, ID, required: true
    argument :as, ID, required: true

    def resolve(id:, as:)
      # OTEL breadcrumbs if you’re using it
      OpenTelemetry::Trace.current_span.add_event("graphql.account_with_parents", attributes: { id: id, as: as }) rescue nil

      records = []
      Account.with_headers('pad-user-id' => as) do
        records = Account.with_parents(id)
      end

      # Ensure it’s an array of AR objects in the expected order.
      # If your REST returns [self, parent, grandparent], you’re done.
      # If it’s reversed, flip here:
      # records = records.reverse

      records
    rescue ActiveResource::ResourceNotFound
      []  # or raise GraphQL::ExecutionError.new("Account not found")
    end
  end
end
