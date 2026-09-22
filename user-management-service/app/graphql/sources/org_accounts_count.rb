# frozen_string_literal: true
# app/graphql/sources/org_accounts_count.rb
module Sources
  class OrgAccountsCount < GraphQL::Dataloader::Source
    def initialize(as:)
      @as = as
    end

    def fetch(org_ids)
      AuthorizationContext.as_requesting_user(user_id: @as) do
        org_ids.map do |id|
          counts = OrganizationAccount.accounts_counts(id)
          raise "Organization count returned the wrong scope" unless counts.fetch(:organization_id) == id
          counts.fetch(:accounts_count).to_i
        end
      end
    end
  end
end
