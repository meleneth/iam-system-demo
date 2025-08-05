# spec/factories/accounts.rb
require 'ostruct'
require 'securerandom'

FactoryBot.define do
  factory :account, class: OpenStruct do
    id { SecureRandom.uuid }
    organization_id { SecureRandom.uuid }
    parent_account_id { nil }

    initialize_with { new(attributes) }

    trait :with_parent do
      transient do
        parent { build(:account) }
      end

      parent_account_id { parent.id }
    end
  end

  # ⬇️ This is a top-level factory, not nested
  factory :account_hierarchy, class: Array do
    skip_create

    transient do
      depth { 3 }
    end

    initialize_with do
      parent_id = nil
      hierarchy = Array.new(depth) do
        account = OpenStruct.new(
          id: SecureRandom.uuid,
          organization_id: SecureRandom.uuid,
          parent_account_id: parent_id
        )
        parent_id = account.id
        account
      end

      hierarchy.reverse!
    end
  end
end
