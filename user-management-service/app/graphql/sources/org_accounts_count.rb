# frozen_string_literal: true
# app/graphql/sources/org_accounts_count.rb
module Sources
  class OrgAccountsCount < GraphQL::Dataloader::Source
    def initialize(as:)
      @as = as
    end

    def fetch(org_ids)
      map = OrganizationAccount.accounts_counts(org_ids)
      Rails.logger.info map
      Rails.logger.info org_ids
      org_ids.map { |id| (map[:organization_id] == id ? map[:accounts_count] : 0).to_i }
    end
  end
end
