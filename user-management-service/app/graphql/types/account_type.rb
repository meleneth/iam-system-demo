# app/graphql/types/account_type.rb
module Types
  class AccountType < BaseObject
    field :id,   ID,     null: false
    field :name, String, null: false
    field :parent_account_id, ID, null: true
    field :users, [Types::UserType], null: false

    def users
      # Prefer preloaded hash set by the resolver
      map = context[:users_by_account_id]
      if map
        map[object.id] || []
      else
        # Fallback (single-account fetch) if someone queries Account standalone
        as = context[:as] # may be nil if not set; keep it optional
        Account.with_headers('pad-user-id' => as) do
          User.find(:all, params: { account_id: [object.id] })
        end
      end
    end
  end
end
