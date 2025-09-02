# app/graphql/types/organization_type.rb
module Types
  class OrganizationType < BaseObject
    field :id, ID, null: false
    field :name, String, null: false
    field :accounts, [Types::AccountType], null: false
    field :accounts_count, Integer, null: false

    def accounts_count
      dataloader
        .with(Sources::OrgAccountsCount, as: context[:as])
        .load(object.id)
    end

    def accounts
      # We want to load all accounts for this org
      OrganizationAccount.with_headers("pad-user-id" => context[:as]) do
        org_accounts = OrganizationAccount.find(:all, params: {organization_id: object.id})
        Account.with_headers("pad-user-id" => context[:as]) do
          Account.find(:all, params: { id: org_accounts.map(&:account_id) })
        end
      end
    end
  end
end

