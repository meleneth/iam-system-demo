# app/graphql/types/group_type.rb
module Types
  class GroupType < Types::BaseObject
    field :id,   ID,     null: false
    field :name, String, null: false
  end
end
