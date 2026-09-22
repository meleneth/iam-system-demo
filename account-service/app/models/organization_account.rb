# frozen_string_literal: true

# app/models/organization.rb
class OrganizationAccount < RemoteResource
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

    Instrumentation.trace("organization_accounts.lookup", attributes: { "scope.count" => account_ids.size }) do
      outgoing_headers, body = begin
        request_headers = AuthorizationContext.transport_headers.merge("Content-Type" => "application/json")
        [request_headers, { account_ids: account_ids }.to_json]
      end
      response = Faraday.post(url) do |req|
        outgoing_headers.each { |key, value| req.headers[key] = value }
        req.body = body
      end

      raise "Failed to get org accounts for account_ids #{account_ids}" unless response.status == 200

      data = begin
        JSON.parse(response.body)
      end
      begin
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

end
