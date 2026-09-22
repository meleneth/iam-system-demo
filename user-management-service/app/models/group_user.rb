# frozen_string_literal: true

# app/models/group_user.rb
class GroupUser < AuthorizedResource::Base
  requires_read_capability "group.read", scope_type: "Group", target: :group_id, iam: %w[IAM_SYSTEM]
  requires_read_capability "account.users.read", scope_type: "Group", target: :group_id
  read_only!(iam: %w[IAM_SYSTEM])
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "group_users"

  # Optional: handle nested resources, errors, etc.
 
  def self.search(params)
    authorized_read("search") do
      raw = connection.post(
        "/group_users/search",
        params.to_json,
        headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
      )
      ActiveSupport::JSON.decode(raw.body).map { |attrs| new(attrs) }
    end
  end
end
