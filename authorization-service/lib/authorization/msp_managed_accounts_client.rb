# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Authorization
  class MspManagedAccountsClient
    DEFAULT_BASE_URL = "http://organization-service:80"

    def initialize(base_url: ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", DEFAULT_BASE_URL))
      @base_url = base_url
    end

    def page(msp_account_id:, continuance: nil)
      uri = URI.join(@base_url, "/internal/msp_managed_accounts/#{msp_account_id}")
      uri.query = URI.encode_www_form(continuance: continuance) if continuance

      request = Net::HTTP::Get.new(uri)
      request["pad-user-id"] = "IAM_SYSTEM"
      OpenTelemetry.propagation.inject(request)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      raise "organization-service MSP lookup failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
