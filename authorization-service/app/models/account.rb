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
    propagated_headers = temp_headers.dup
    OpenTelemetry.propagation.inject(propagated_headers)
    self.headers.merge!(propagated_headers)
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
    raw = connection.post(
      "/accounts_with_parents",
      { account_ids: Array(account_ids) }.to_json,
      headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
    )

    data = ActiveSupport::JSON.decode(raw.body)

    # Expecting: [[account1_attrs, parent1_attrs...], [...], ...]
    data.map do |account_group|
      account_group.map { |attrs| new(attrs) }
    end
  end


  # Optional: handle nested resources, errors, etc.
end
