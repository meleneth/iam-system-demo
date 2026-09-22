# app/graphql/resolvers/account_hierarchies_resolver.rb
module Resolvers
  class AccountHierarchiesResolver < GraphQL::Schema::Resolver

    type [[Types::AccountType]], null: false

    argument :ids, [ID], required: true
    argument :as, ID, required: true

    def resolve(ids:, as:)
      context.scoped_set!(:as, as)

      hierarchies = AuthorizationContext.as_requesting_user(user_id: as) do
        hierarchies = Account.with_parents_batch_ordered(ids)

        account_ids = hierarchies.flatten.map(&:id).uniq
        users = account_ids.each_slice(IamDemo.batch_size).flat_map do |ids|
          User.search(account_id: ids)
        end
        context.scoped_set!(:users_by_account_id, users.group_by(&:account_id))
        hierarchies
      end

      hierarchies
    end
  end
end
