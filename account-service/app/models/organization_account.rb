# frozen_string_literal: true

# app/models/organization.rb
class OrganizationAccount < AuthorizedResource::Base
  requires_read_capability "organization.read.accounts", scope_type: "Organization", target: :organization_id, iam: %w[IAM_SYSTEM]
  requires_read_capability "account.read", scope_type: "Account", target: :account_id
  read_only!(iam: %w[IAM_SYSTEM])
  self.site = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "organization_accounts"

  # Optional: handle nested resources, errors, etc.
  def organization
    Organization.find(self.organization_id)
  end

  def self.account_ids_for_organization_by_account_id(account_id)
    raise "One account_id only please" if account_id.is_a? Array

    account_ids_for_organizations_by_account_ids([account_id]).fetch(account_id.to_s)
  end

  def self.account_ids_for_organizations_by_account_ids(account_ids)
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organization_account_ids/for_account_ids"
    authorized_read("organization_lookup", records: account_ids.map { |id| { account_id: id } }) do
      outgoing_headers = AuthorizationContext.transport_headers.merge("Content-Type" => "application/json")
      body = { account_ids: account_ids }.to_json
      response = Faraday.post(url) do |req|
        outgoing_headers.each { |key, value| req.headers[key] = value }
        req.body = body
      end
      raise "Failed to get org accounts for account_ids #{account_ids}" unless response.status == 200
      data = JSON.parse(response.body)
      organizations = data.fetch("organizations")
      data.fetch("account_to_organization").to_h do |account_id, organization_id|
        [account_id.to_s, {
          organization: Organization.new(id: organization_id),
          account_ids: organizations.fetch(organization_id.to_s)
        }]
      end
    end
  end

end
