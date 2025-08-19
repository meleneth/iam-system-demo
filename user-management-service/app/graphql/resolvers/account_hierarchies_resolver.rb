# app/graphql/resolvers/account_hierarchies_resolver.rb
module Resolvers
  class AccountHierarchiesResolver < GraphQL::Schema::Resolver
    type [[Types::AccountType]], null: false

    argument :ids, [ID], required: true
    argument :as, ID, required: true

    def resolve(ids:, as:)
      OpenTelemetry::Trace.current_span.add_event("graphql.account_hierarchies", attributes: { ids_count: ids.size, as: as }) rescue nil

      hierarchies = []
      Account.with_headers('pad-user-id' => as) do
        # If you have your batch endpoint:
        # arrays = Account.with_parents_batch(ids)
        # hierarchies = arrays
        #
        # If not, do a minimal serial fallback for now (replace with a dataloader later):
        hierarchies = ids.map { |i| Account.with_parents(i) }
      end

      hierarchies
    end
  end
end
