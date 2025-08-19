# app/graphql/types/account_type.rb
module Types
  class AccountType < BaseObject
    field :id,   ID,     null: false
    field :name, String, null: false
    field :parent_account_id, ID, null: true
  end
end
