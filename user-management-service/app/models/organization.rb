# frozen_string_literal: true

# app/models/organization.rb
class Organization < RemoteResource
  self.site = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", "http://organization-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "organizations"

  # Optional: handle nested resources, errors, etc.
 
  def self.random_internal
    AuthorizationContext.current!
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/random/organization"
    response = Faraday.get(url) do |req|
      headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get random organization: #{response.status} #{response.body}" unless response.status == 200

    new(JSON.parse(response.body))
  end
end
