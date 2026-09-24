# frozen_string_literal: true

require "authorized_resource"
require "faraday"
require "json"

class CapabilityGrant < AuthorizedResource::Base
  self.site = ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  self.format = :json
  self.include_format_in_path = false
  self.primary_key = "id"
  self.collection_name = "capability_grants"

  schema do
    string "id"
    string "group_id"
    string "permission"
    string "scope_type"
    string "scope_id"
  end

  class << self
    def admin_user_for_organization(organization_id)
      authorized_read("admin_user") do
        response = Faraday.get(endpoint("internal/admin_users/organization/#{organization_id}")) do |request|
          headers.each { |key, value| request.headers[key] = value }
        end
        return nil if response.status == 404
        unless response.status == 200
          raise "Failed to find organization admin for #{organization_id}: #{response.status} #{response.body}"
        end
        JSON.parse(response.body, symbolize_names: true)
      end
    end

    def capabilities(scope_type, scope_id, user_id:)
      context = AuthorizationContext.current!
      unless context.user_id == user_id.to_s
        raise AuthorizationContext::InvalidContextError, "authorization actor mismatch"
      end

      response = Faraday.get(endpoint("capabilities/#{scope_type}/#{scope_id}")) do |request|
        headers.each { |key, value| request.headers[key] = value }
      end
      unless response.status == 200
        raise "Failed to get #{scope_type} capabilities for #{scope_id}: #{response.status} #{response.body}"
      end
      JSON.parse(response.body)
    end

    private

    def endpoint(path)
      "#{site.to_s.delete_suffix("/")}/#{path.delete_prefix("/")}"
    end
  end
end
