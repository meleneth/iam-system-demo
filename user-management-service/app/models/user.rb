# frozen_string_literal: true

# app/models/user.rb
class User < ActiveResource::Base
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "users"

  # Optional: handle nested resources, errors, etc.
 
  def self.with_headers(temp_headers)
    old_headers = headers.dup
    self.headers.merge!(temp_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  def can(scope_type, permission, scope_id)
    scope_ids = Array(scope_id)
    query_string = URI.encode_www_form(scope_ids.map { |id| ["scope_id[]", id] })

    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/can/#{scope_type}/#{permission}?#{query_string}"

    response = Faraday.get(url) do |req|
      req.headers["pad-user-id"] = id
    end

    response.status == 200
  end

  def self.users_count(account_ids)
    account_ids = Array(account_ids)
    query_string = URI.encode_www_form(account_ids.map { |id| ["account_id[]", id] })

    url = "#{Env::USER_SERVICE_API_BASE_URL}/accounts/users/counts?#{query_string}"

    response = Faraday.get(url)

    raise "Error getting Account's User counts" unless response.status == 200
    data = JSON.parse(response.body, symbolize_names: true)
    data
  end
end
