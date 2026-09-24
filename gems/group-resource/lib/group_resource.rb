# frozen_string_literal: true

require "authorized_resource"
require "faraday"
require "json"

class Group < AuthorizedResource::Base
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json
  self.primary_key = "id"
  self.collection_name = "groups"

  class << self
    def search(params)
      authorized_read("search") do
        raw = connection.post(
          "/groups/search",
          params.to_json,
          headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
        )
        ActiveSupport::JSON.decode(raw.body).map { |attributes| new(attributes) }
      end
    end

    def groups_count(account_ids)
      authorized_read("counts") do
        outgoing_headers = headers.merge("Content-Type" => "application/json")
        response = Faraday.post(endpoint("accounts/groups/counts")) do |request|
          outgoing_headers.each { |key, value| request.headers[key] = value }
          request.body = {account_id: Array(account_ids)}.to_json
        end
        raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
        raise "Error getting account group counts" unless response.status == 200
        JSON.parse(response.body, symbolize_names: true)
      end
    end

    private

    def endpoint(path)
      "#{site.to_s.delete_suffix("/")}/#{path.delete_prefix("/")}"
    end
  end
end
