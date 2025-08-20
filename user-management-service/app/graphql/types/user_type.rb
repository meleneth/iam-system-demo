# app/graphql/types/user_type.rb
module Types
  class UserType < Types::BaseObject
    field :id, ID, null: false
    field :email, String, null: false
    field :name, String, null: true
    field :account_id, ID, null: false
        field :groups, [Types::GroupType], null: false
    field :group_names, [String], null: false

    def groups
      ctx = context[:groups_by_user_id]
      return ctx[object.id] if ctx
      # Fallback (only if someone queries User standalone)
      as = context[:as]
      groups = []
      Account.with_headers('pad-user-id' => as) do
        gus = GroupUser.find(:all, params: { user_id: [object.id] })
        gids = gus.map(&:group_id).uniq
        groups = gids.empty? ? [] : Group.find(:all, params: { id: gids })
      end
      groups
    end

    def group_names
      groups.map(&:name)
    end
  end
end
