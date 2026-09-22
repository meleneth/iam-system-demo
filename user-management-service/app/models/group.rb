# frozen_string_literal: true

# app/models/user.rb
class Group < AuthorizedResource::Base
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "groups"

  # Optional: handle nested resources, errors, etc.
 
  def self.search(params)
    authorized_read("search") do
      raw = connection.post(
        "/groups/search",
        params.to_json,
        headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
      )
      ActiveSupport::JSON.decode(raw.body).map { |attrs| new(attrs) }
    end
  end

  def self.groups_count(account_ids)
    account_ids = Array(account_ids)
    authorized_read("counts") do
      url = "#{Env::GROUP_SERVICE_API_BASE_URL}/accounts/groups/counts"
      outgoing_headers = headers.dup
      OpenTelemetry.propagation.inject(outgoing_headers)
      response = Faraday.post(url) do |req|
        outgoing_headers.each { |key, value| req.headers[key] = value }
        req.headers["Content-Type"] = "application/json"
        req.body = { account_id: account_ids }.to_json
      end
      raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
      raise "Error getting Account's Group counts" unless response.status == 200
      data = JSON.parse(response.body, symbolize_names: true)
      Rails.logger.info data
      data
    end
  end
end
