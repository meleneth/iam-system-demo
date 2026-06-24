# frozen_string_literal: true

# app/models/organization.rb
class OrganizationAccount < ActiveResource::Base
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

  def self.with_headers(temp_headers)
    old_headers = headers.dup
    propagated_headers = temp_headers.dup
    OpenTelemetry.propagation.inject(propagated_headers)
    self.headers.merge!(propagated_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  def self.account_ids_for_organization_by_account_id(account_id)
    raise "One account_id only please" if account_id.is_a? Array
    # TODO FIXME SECURITY - account_id is passed to us as a url param, SANITIZE IT
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organization_account_ids/for_account_id/#{account_id}"

    pad_user_id = headers["pad-user-id"]
    outgoing_headers = { "pad-user-id" => pad_user_id }
    OpenTelemetry.propagation.inject(outgoing_headers)
    response = Faraday.get(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get org accounts for account_id #{account_id}" unless response.status == 200

    data = JSON.parse(response.body, symbolize_names: true)
    data[:organization] = Organization.new(data[:organization])
    return data
  end

  def self.accounts_counts(org_id)
    if org_id.is_a? Array
      raise "One organization_id only please" unless org_id.count == 1 
      org_id = org_id[0]
    end
    pad_user_id = headers["pad-user-id"]
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organizations/accounts/counts/#{org_id}"

    pad_user_id = headers["pad-user-id"]
    outgoing_headers = { "pad-user-id" => pad_user_id }
    OpenTelemetry.propagation.inject(outgoing_headers)
    response = Faraday.get(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Error getting Organization's Account counts" unless response.status == 200

    JSON.parse(response.body, symbolize_names: true)
  end
end
