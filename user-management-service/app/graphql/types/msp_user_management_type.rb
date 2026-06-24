# frozen_string_literal: true

module Types
  class MspUserManagementType < Types::BaseObject
    field :loading, Boolean, null: false
    field :loaded_count, Integer, null: false
    field :total_count, Integer, null: false
    field :message, String, null: false
    field :accounts, [Types::MspManagedAccountType], null: false

    def loading
      object.fetch(:loading)
    end

    def loaded_count
      object.fetch(:loaded_count)
    end

    def total_count
      object.fetch(:total_count)
    end

    def message
      object.fetch(:message)
    end

    def accounts
      object.fetch(:accounts)
    end
  end
end
