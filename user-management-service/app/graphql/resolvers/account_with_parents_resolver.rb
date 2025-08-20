# app/graphql/resolvers/account_with_parents_resolver.rb
module Resolvers
  class AccountWithParentsResolver < GraphQL::Schema::Resolver
    type [Types::AccountType], null: false

    argument :id, ID, required: true
    argument :as, ID, required: true
    TRACER = OpenTelemetry.tracer_provider.tracer('account_with_parent_resolver', '1.0.0')

    def resolve(id:, as:)
      context[:as] = as
      TRACER.in_span("Account.with_parents()") do
        accounts = []
        Account.with_headers('pad-user-id' => as) do
          accounts = Account.with_parents(id)
        end

        # Preload users in one call
        account_ids = accounts.map(&:id).uniq
        users = []
        User.with_headers('pad-user-id' => as) do
          users = User.find(:all, params: { account_id: account_ids })
        end
        context[:users_by_account_id] = users.group_by(&:account_id)

        user_ids = users.map(&:id).uniq

        group_users = []
        groups = []

        GroupUser.with_headers('pad-user-id' => as) do
          Group.with_headers('pad-user-id' => as) do
            group_users = user_ids.empty? ? [] : GroupUser.find(:all, params: { user_id: user_ids })
            group_ids = group_users.map(&:group_id).uniq
            groups = group_ids.empty? ? [] : Group.find(:all, params: { id: group_ids })
          end
        end

        groups_by_id = groups.index_by(&:id)
        groups_by_user_id = Hash.new { |h, k| h[k] = [] }
        group_users.each do |gu|
          if (g = groups_by_id[gu.group_id])
            groups_by_user_id[gu.user_id] << g
          end
        end

        context[:groups_by_user_id] = groups_by_user_id

        accounts
      end
    end
  end
end
