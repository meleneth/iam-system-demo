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
      account_ids = OrganizationAccount.with_headers("pad-user-id" => context[:as]) do
        OrganizationAccount.find(:all, params: { organization_id: object.id }).map(&:account_id)
      end
      dataloader.with(Sources::AccountById, as: context[:as],
        otel_ctx: context[:otel_ctx] || OpenTelemetry::Context.current).load_all(account_ids)
    end
  end
end
