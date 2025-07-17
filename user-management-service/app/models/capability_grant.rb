# frozen_string_literal: true

# app/models/account.rb
class CapabilityGrant < ActiveResource::Base
  self.site = ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL") # e.g., http://account-service:80/
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
end
