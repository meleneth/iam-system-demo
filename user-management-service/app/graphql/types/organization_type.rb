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
          org_accounts.map(&:account_id).each_slice(IamDemo.batch_size).flat_map do |account_ids|
            Account.search(id: account_ids)
          end
        end
      end
    end
  end
end
