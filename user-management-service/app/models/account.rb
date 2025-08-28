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

  def self.with_headers(temp_headers)
    old_headers = headers.dup
    self.headers.merge!(temp_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "accounts"

  def self.with_parents(account_id)
    path = "/account_with_parents/#{account_id}.json"
    raw = connection.get(path, headers)
    data = ActiveSupport::JSON.decode(raw.body)
    data.map { |attrs| new(attrs) }
  end

  def self.with_parents_batch(account_ids)
    query_string = URI.encode_www_form(account_ids.map { |id| ['account_ids[]', id] })
    path = "/accounts_with_parents.json?#{query_string}"

    raw = connection.get(path, headers)
    data = ActiveSupport::JSON.decode(raw.body)

    # Expecting: [[account1_attrs, parent1_attrs...], [...], ...]
    data.map do |account_group|
      account_group.map { |attrs| new(attrs) }
    end
  end


  # Optional: handle nested resources, errors, etc.
end
