# frozen_string_literal: true

# app/models/account.rb
class CapabilityGrant < ActiveResource::Base
  self.site = ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  self.format = :json

  self.include_format_in_path = false

  schema do
    string 'id'
    string 'user_id'
    string 'permission'
    string 'scope_type'
    string 'uuid'
  end

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "capability_grants"

  # Optional: handle nested resources, errors, etc.
  def self.with_headers(temp_headers)
    old_headers = headers.dup
    propagated_headers = temp_headers.dup
    OpenTelemetry.propagation.inject(propagated_headers)
    self.headers.merge!(propagated_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end
end
