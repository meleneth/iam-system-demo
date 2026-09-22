# app/models/user.rb
class User < AuthorizedResource::Base
  requires_read_capability "account.users.read", scope_type: "Account", target: :account_id, iam: %w[IAM_SYSTEM]
  read_only!(iam: %w[IAM_SYSTEM])
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "users"

end
