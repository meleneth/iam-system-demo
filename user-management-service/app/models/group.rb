# frozen_string_literal: true

# app/models/user.rb
class Group < ActiveResource::Base
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "groups"

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

  def self.search(params)
    raw = connection.post(
      "/groups/search",
      params.to_json,
      headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
    )

    decoded = ActiveSupport::JSON.decode(raw.body)

    decoded.map { |attrs| new(attrs) }
  end

  def self.groups_count(account_ids)
    account_ids = Array(account_ids)
    query_string = URI.encode_www_form(account_ids.map { |id| ["account_id[]", id] })

    url = "#{Env::GROUP_SERVICE_API_BASE_URL}/accounts/groups/counts?#{query_string}"

    outgoing_headers = headers.dup
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.get(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Error getting Account's Group counts" unless response.status == 200

    data = JSON.parse(response.body, symbolize_names: true)
    Rails.logger.info data
    data
  end
end
