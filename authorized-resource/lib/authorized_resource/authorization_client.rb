# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AuthorizedResource
  class AuthorizationClient
    def initialize(base_url:)
      @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
    end

    # Returns authorized capabilities by scope. Capabilities mode retrieves the
    # complete capability set once per scope type. /can mode asks one precise,
    # batched question per scope type and required capability.
    def capabilities(targets)
      case authorization_mode
      when "capabilities"
        capabilities_for(targets)
      when "can"
        can_for(targets)
      else
        raise AuthorizationTransportError,
          "unsupported AUTHORIZATION_CHECK_MODE=#{authorization_mode.inspect}"
      end
    end

    private

    def authorization_mode
      ENV.fetch("AUTHORIZATION_CHECK_MODE", "can")
    end

    def capabilities_for(targets)
      targets.group_by(&:scope_type).each_with_object({}) do |(scope_type, scoped_targets), result|
        ids = scoped_targets.map(&:scope_id).uniq
        result[scope_type] = request_capabilities(scope_type, ids)
      end
    end

    def can_for(targets)
      result = Hash.new { |types, scope_type| types[scope_type] = Hash.new { |ids, scope_id| ids[scope_id] = [] } }
      targets.group_by { |target| [target.scope_type, target.capability] }.each do |(scope_type, capability), scoped_targets|
        ids = scoped_targets.map(&:scope_id).uniq
        next unless request_can(scope_type, capability, ids)

        ids.each { |scope_id| result[scope_type][scope_id] << capability }
      end
      result.each_value do |scopes|
        scopes.each { |scope_id, capabilities| scopes[scope_id] = capabilities.uniq.freeze }
        scopes.default_proc = nil
        scopes.freeze
      end
      result.default_proc = nil
      result.freeze
    end

    def request_capabilities(scope_type, scope_ids)
      uri = URI.join(@base_url, "capabilities/#{URI.encode_www_form_component(scope_type)}")
      response = post(uri, scope_ids)
      unless response.is_a?(Net::HTTPSuccess)
        raise AuthorizationTransportError,
          "authorization capability lookup failed with HTTP #{response.code}"
      end

      decoded = JSON.parse(response.body)
      unless decoded.is_a?(Hash)
        raise AuthorizationTransportError, "authorization capability lookup returned an invalid response"
      end

      decoded.transform_keys(&:to_s).transform_values { |values| Array(values).map(&:to_s).freeze }.freeze
    rescue JSON::ParserError => error
      raise AuthorizationTransportError, "authorization capability lookup failed: #{error.class}"
    end

    def request_can(scope_type, capability, scope_ids)
      uri = URI.join(@base_url,
        "can/#{URI.encode_www_form_component(scope_type)}/#{URI.encode_www_form_component(capability)}")
      response = post(uri, scope_ids)
      return true if response.is_a?(Net::HTTPSuccess)
      return false if response.is_a?(Net::HTTPForbidden)

      raise AuthorizationTransportError, "authorization /can lookup failed with HTTP #{response.code}"
    end

    def post(uri, scope_ids)
      request = Net::HTTP::Post.new(uri)
      AuthorizationContext.transport_headers.each { |key, value| request[key] = value }
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      OpenTelemetry.propagation.inject(request)
      request.body = JSON.generate(scope_id: scope_ids)
      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 30
      ) { |http| http.request(request) }
    rescue AuthorizationContext::Error, AuthorizationTransportError
      raise
    rescue IOError, SystemCallError, Timeout::Error, SocketError, URI::Error => error
      raise AuthorizationTransportError, "authorization lookup failed: #{error.class}"
    end
  end
end
