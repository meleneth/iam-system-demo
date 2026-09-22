# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AuthorizedResource
  class AuthorizationClient
    def initialize(base_url:)
      @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
    end

    # Returns capabilities by scope in one request per scope type. The caller
    # evaluates alternatives record-by-record so a mixed collection remains safe.
    def capabilities(targets)
      targets.group_by(&:scope_type).each_with_object({}) do |(scope_type, scoped_targets), result|
        ids = scoped_targets.map(&:scope_id).uniq
        result[scope_type] = request(scope_type, ids)
      end
    end

    private

    def request(scope_type, scope_ids)
      uri = URI.join(@base_url, "capabilities/#{URI.encode_www_form_component(scope_type)}")
      request = Net::HTTP::Post.new(uri)
      AuthorizationContext.transport_headers.each { |key, value| request[key] = value }
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      OpenTelemetry.propagation.inject(request)
      request.body = JSON.generate(scope_id: scope_ids)
      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 30
      ) { |http| http.request(request) }
      unless response.is_a?(Net::HTTPSuccess)
        raise AuthorizationTransportError,
          "authorization capability lookup failed with HTTP #{response.code}"
      end

      decoded = JSON.parse(response.body)
      unless decoded.is_a?(Hash)
        raise AuthorizationTransportError, "authorization capability lookup returned an invalid response"
      end

      decoded.transform_keys(&:to_s).transform_values { |values| Array(values).map(&:to_s).freeze }.freeze
    rescue AuthorizationContext::Error, AuthorizationTransportError
      raise
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError, URI::Error => error
      raise AuthorizationTransportError, "authorization capability lookup failed: #{error.class}"
    end
  end
end
