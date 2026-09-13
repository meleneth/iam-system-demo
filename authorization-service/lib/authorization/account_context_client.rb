# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Authorization
  class AccountContextClient
    DEFAULT_BASE_URL = "http://organization-auth-service:80"

    def initialize(base_url: ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", DEFAULT_BASE_URL))
      @base_url = base_url
    end

    def providers_for(account_ids:)
      uri = URI.join(@base_url, "/internal/auth/account_providers")
      request = Net::HTTP::Post.new(uri)
      request["pad-user-id"] = "IAM_SYSTEM_AUTH"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      OpenTelemetry.propagation.inject(request)
      request.body = { account_ids: account_ids }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
        http.request(request)
      end

      raise "organization-service auth account context lookup failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
