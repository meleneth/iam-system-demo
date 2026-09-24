# frozen_string_literal: true

require "authorized_resource"

class GroupUser < AuthorizedResource::Base
  self.site = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
  self.format = :json
  self.primary_key = "id"
  self.collection_name = "group_users"

  def self.search(params)
    authorized_read("search") do
      raw = connection.post(
        "/group_users/search",
        params.to_json,
        headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
      )
      ActiveSupport::JSON.decode(raw.body).map { |attributes| new(attributes) }
    end
  end
end
