# frozen_string_literal: true

# app/models/account.rb
class Account < ActiveResource::Base
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
    path = "/account_with_parents/#{account_id}.json"
    raw = connection.get(path)
    data = ActiveSupport::JSON.decode(raw.body)
    data.map { |attrs| new(attrs) }
  end

  # Optional: handle nested resources, errors, etc.
end
