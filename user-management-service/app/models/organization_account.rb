# frozen_string_literal: true

# app/models/organization.rb
class OrganizationAccount < RemoteResource
  self.site = Env::ORGANIZATION_SERVICE_API_BASE_URL # e.g., http://user-service:3000/
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

    result = account_ids_for_organizations_by_account_ids([account_id]).fetch(account_id.to_s)
    result[:organization] = Organization.find(result[:organization].id)
    result
  end

  def self.account_ids_for_organizations_by_account_ids(account_ids)
    AuthorizationContext.current!
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organization_account_ids/for_account_ids"

    outgoing_headers = AuthorizationContext.transport_headers.merge("Content-Type" => "application/json")
    OpenTelemetry.propagation.inject(outgoing_headers)
    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.body = { account_ids: account_ids }.to_json
    end

    raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
    raise "Failed to get org accounts for account_ids #{account_ids}" unless response.status == 200

    data = JSON.parse(response.body)
    organizations = data.fetch("organizations")

    data.fetch("account_to_organization").to_h do |account_id, organization_id|
      [
        account_id.to_s,
        {
          organization: Organization.new(id: organization_id),
          account_ids: organizations.fetch(organization_id.to_s)
        }
      ]
    end
  end

  def self.accounts_counts(org_id)
    AuthorizationContext.current!
    if org_id.is_a? Array
      raise "One organization_id only please" unless org_id.count == 1 
      org_id = org_id[0]
    end
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organizations/accounts/counts/#{org_id}"

    outgoing_headers = AuthorizationContext.transport_headers.dup
    OpenTelemetry.propagation.inject(outgoing_headers)
    response = Faraday.get(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
    raise "Error getting Organization's Account counts" unless response.status == 200

    JSON.parse(response.body, symbolize_names: true)
  end

  def self.random_account_for_organization(organization_id)
    AuthorizationContext.current!
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/random/organizations/#{organization_id}/account"
    response = Faraday.get(url) do |req|
      headers.each { |key, value| req.headers[key] = value }
    end

    raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
    raise "Failed to get random account for organization #{organization_id}: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body, symbolize_names: true)
  end
end
