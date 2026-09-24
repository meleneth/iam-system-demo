# frozen_string_literal: true

require "authorized_resource"
require "faraday"
require "json"

class OrganizationAccount < AuthorizedResource::Base
  self.site = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", "http://organization-service:80")
  self.format = :json
  self.primary_key = "id"
  self.collection_name = "organization_accounts"

  def organization
    Organization.find(organization_id)
  end

  class << self
    def account_ids_for_organization_by_account_id(account_id)
      raise ArgumentError, "one account_id only" if account_id.is_a?(Array)

      result = account_ids_for_organizations_by_account_ids([account_id]).fetch(account_id.to_s)
      result[:organization] = Organization.find(result[:organization].id)
      result
    end

    def account_ids_for_organizations_by_account_ids(account_ids)
      authorized_read("organization_lookup") do
        response = post_json("/organization_account_ids/for_account_ids", account_ids: account_ids)
        raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
        raise "Failed to get organization accounts for #{account_ids}" unless response.status == 200

        data = JSON.parse(response.body)
        organizations = data.fetch("organizations")
        data.fetch("account_to_organization").to_h do |account_id, organization_id|
          [account_id.to_s, {
            organization: Organization.new(id: organization_id),
            account_ids: organizations.fetch(organization_id.to_s)
          }]
        end
      end
    end

    def accounts_counts(organization_id)
      ids = Array(organization_id)
      raise ArgumentError, "one organization_id only" unless ids.one?

      authorized_read("accounts_count") do
        response = get("/organizations/accounts/counts/#{ids.first}")
        raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
        raise "Error getting organization account counts" unless response.status == 200
        JSON.parse(response.body, symbolize_names: true)
      end
    end

    def random_account_for_organization(organization_id)
      authorized_read("random_account") do
        response = get("/internal/random/organizations/#{organization_id}/account")
        raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
        unless response.status == 200
          raise "Failed to get random account for #{organization_id}: #{response.status} #{response.body}"
        end
        JSON.parse(response.body, symbolize_names: true)
      end
    end

    private

    def post_json(path, payload)
      outgoing_headers = AuthorizationContext.transport_headers.merge("Content-Type" => "application/json")
      OpenTelemetry.propagation.inject(outgoing_headers)
      Faraday.post(endpoint(path)) do |request|
        outgoing_headers.each { |key, value| request.headers[key] = value }
        request.body = payload.to_json
      end
    end

    def get(path)
      outgoing_headers = headers.dup
      Faraday.get(endpoint(path)) do |request|
        outgoing_headers.each { |key, value| request.headers[key] = value }
      end
    end

    def endpoint(path)
      "#{site.to_s.delete_suffix("/")}/#{path.delete_prefix("/")}"
    end
  end
end
