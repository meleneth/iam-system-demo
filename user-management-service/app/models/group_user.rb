# frozen_string_literal: true

# app/models/group_user.rb
class GroupUser < ActiveResource::Base
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "group_users"

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
