# frozen_string_literal: true

# app/models/organization.rb
class Organization < ActiveResource::Base
  self.site = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "organizations"

  # Optional: handle nested resources, errors, etc.
 
  def self.with_headers(temp_headers)
    old_headers = headers.dup
    self.headers.merge!(temp_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  def accounts
    account_ids = organization_accounts.map(&:account_id)
    accounts = []
    account_ids.each_slice(5).map do |group|
      accounts.concat(Account.where(id: group).to_a)
    end
    accounts
  end

  def organization_accounts
    OrganizationAccount.find(:all, params: {organization_id: id})
  end
end
