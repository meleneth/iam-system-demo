# app/graphql/resolvers/account_hierarchies_resolver.rb
module Resolvers
  class AccountHierarchiesResolver < GraphQL::Schema::Resolver
    type [[Types::AccountType]], null: false

    argument :ids, [ID], required: true
    argument :as, ID, required: true

    def resolve(ids:, as:)
      context[:as] = as

      hierarchies = []
      Account.with_headers('pad-user-id' => as) do
        # Swap to your batch endpoint when ready
        hierarchies = ids.map { |i| Account.with_parents(i) }
      end

      # Preload users for *all* accounts across all hierarchies
      account_ids = hierarchies.flatten.map(&:id).uniq
      users = []
      Account.with_headers('pad-user-id' => as) do
        users = User.find(:all, params: { account_id: account_ids })
      end
      context[:users_by_account_id] = users.group_by(&:account_id)

      hierarchies
    end
  end
end
