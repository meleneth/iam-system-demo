# app/graphql/resolvers/account_with_parents_resolver.rb
module Resolvers
  class AccountWithParentsResolver < GraphQL::Schema::Resolver
    type [Types::AccountType], null: false

    argument :id, ID, required: true
    argument :as, ID, required: true

    def resolve(id:, as:)
      context[:as] = as

      accounts = []
      Account.with_headers('pad-user-id' => as) do
        accounts = Account.with_parents(id)
      end

      # Preload users in one call
      account_ids = accounts.map(&:id).uniq
      users = []
      Account.with_headers('pad-user-id' => as) do
        users = User.find(:all, params: { account_id: account_ids })
      end
      context[:users_by_account_id] = users.group_by(&:account_id)

      accounts
    end
  end
end
