# frozen_string_literal: true

# app/models/organization.rb
class OrganizationAccount < ActiveResource::Base
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

  def self.with_headers(temp_headers)
    old_headers = headers.dup
    self.headers.merge!(temp_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  def self.for_account(account_id)
    account_ids = Array(account_id)
    query_string = URI.encode_www_form(account_ids.map { |id| ["account_id[]", id] })

    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/organization_accounts/for?#{query_string}"

    response = Faraday.get(url) do |req|
      req.headers.update(headers)
    end

    unless response.success?
      raise "Organization service returned #{response.status}: #{response.body}"
    end

    data = JSON.parse(response.body, symbolize_names: true)

    return data[:organization_id], data[:accounts].map { |attrs| new(attrs) }
  end

end
