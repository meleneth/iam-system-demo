# app/graphql/resolvers/account_with_parents_resolver.rb
module Resolvers
  class AccountWithParentsResolver < GraphQL::Schema::Resolver
    type [Types::AccountType], null: false

    argument :id, ID, required: true
    argument :as, ID, required: true

    TRACER = OpenTelemetry.tracer_provider.tracer('account_with_parent_resolver', '1.0.0')

    def resolve(id:, as:)
      # Stash auth + tracer in context so field resolvers can reuse
      context[:as]     = as
      context[:tracer] = TRACER

      # One logical loader: returns [account, parent, grandparent, ...] for the given id
      context.dataloader
             .with(Sources::AccountsWithParentsById, as: as, tracer: TRACER)
             .load(id)
    end
  end
end
