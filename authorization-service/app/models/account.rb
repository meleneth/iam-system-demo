# frozen_string_literal: true

# app/models/account.rb
class Account < AuthorizedResource::Base
  requires_read_capability "account.read", scope_type: "Account", target: :id, iam: %w[IAM_SYSTEM]
  read_only!(iam: %w[IAM_SYSTEM])
  self.site = ENV.fetch("ACCOUNT_SERVICE_API_BASE_URL") # e.g., http://account-service:80/
  self.format = :json

  self.include_format_in_path = false

  schema do
    string 'id'
    string 'parent_account_id'
    string 'name'
  end

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "accounts"

  def self.with_parents(account_id)
    authorized_read("with_parents") do
      path = "/account_with_parents/#{account_id}.json"
      raw = connection.get(path, headers)
      data = ActiveSupport::JSON.decode(raw.body)
      data.map { |attrs| new(attrs) }
    end
  end

  def self.with_parents_batch(account_ids)
    authorized_read("with_parents_batch") do
      raw = connection.post(
        "/accounts_with_parents",
        { account_ids: Array(account_ids) }.to_json,
        headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
      )
      ActiveSupport::JSON.decode(raw.body).map do |account_group|
        account_group.map { |attrs| new(attrs) }
      end
    end
  end


  # Optional: handle nested resources, errors, etc.
end
