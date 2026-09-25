# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AuthorizedModel
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
        raise AuthorizedResource::AuthorizationTransportError,
          "unsupported AUTHORIZATION_CHECK_MODE=#{authorization_mode.inspect}"
      end
    end

    def decisions(targets)
      targets = Array(targets).uniq
      case authorization_mode
      when "capabilities"
        capabilities = capabilities_for(targets)
        targets.to_h do |target|
          allowed = capabilities.fetch(target.scope_type, {}).fetch(target.scope_id, []).include?(target.capability)
          [target, allowed]
        end
      when "can"
        targets.each_slice(batch_size).each_with_object({}) do |chunk, decisions|
          decisions.merge!(request_decisions(chunk))
        end
      else
        raise AuthorizedResource::AuthorizationTransportError,
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
        result[scope_type] = ids.each_slice(batch_size).each_with_object({}) do |chunk, scopes|
          scopes.merge!(request_capabilities(scope_type, chunk))
        end
      end
    end

    def can_for(targets)
      result = Hash.new { |types, scope_type| types[scope_type] = Hash.new { |ids, scope_id| ids[scope_id] = [] } }
      targets.group_by { |target| [target.scope_type, target.capability] }.each do |(scope_type, capability), scoped_targets|
        ids = scoped_targets.map(&:scope_id).uniq
        ids.each_slice(batch_size) do |chunk|
          next unless request_can(scope_type, capability, chunk)

          chunk.each { |scope_id| result[scope_type][scope_id] << capability }
        end
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
        raise AuthorizedResource::AuthorizationTransportError,
          "authorization capability lookup failed with HTTP #{response.code}"
      end

      decoded = JSON.parse(response.body)
      unless decoded.is_a?(Hash)
        raise AuthorizedResource::AuthorizationTransportError,
          "authorization capability lookup returned an invalid response"
      end

      decoded.transform_keys(&:to_s).transform_values { |values| Array(values).map(&:to_s).freeze }.freeze
    rescue JSON::ParserError => error
      raise AuthorizedResource::AuthorizationTransportError,
        "authorization capability lookup failed: #{error.class}"
    end

    def batch_size
      Integer(ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000"), 10).then do |size|
        raise ArgumentError, "IAM_DEMO_BATCH_SIZE must be between 1 and 10000" unless (1..10_000).cover?(size)
        size
      end
    rescue ArgumentError
      raise ArgumentError, "IAM_DEMO_BATCH_SIZE must be between 1 and 10000"
    end

    def request_can(scope_type, capability, scope_ids)
      uri = URI.join(@base_url,
        "can/#{URI.encode_www_form_component(scope_type)}/#{URI.encode_www_form_component(capability)}")
      response = post(uri, scope_ids)
      return true if response.is_a?(Net::HTTPSuccess)
      return false if response.is_a?(Net::HTTPForbidden)

      raise AuthorizedResource::AuthorizationTransportError,
        "authorization /can lookup failed with HTTP #{response.code}"
    end

    def request_decisions(targets)
      uri = URI.join(@base_url, "internal/decisions")
      response = post_json(uri, targets: targets.map do |target|
        { scope_type: target.scope_type, scope_id: target.scope_id, permission: target.capability }
      end)
      unless response.is_a?(Net::HTTPSuccess)
        raise AuthorizedResource::AuthorizationTransportError,
          "authorization decision lookup failed with HTTP #{response.code}"
      end

      decoded = JSON.parse(response.body)
      rows = decoded.is_a?(Hash) ? decoded["decisions"] : nil
      unless rows.is_a?(Array) && rows.size == targets.size
        raise AuthorizedResource::AuthorizationTransportError,
          "authorization decision lookup returned an invalid response"
      end

      expected = targets.index_by { |target| [target.scope_type, target.scope_id, target.capability] }
      decisions = rows.each_with_object({}) do |row, result|
        unless row.is_a?(Hash) && [true, false].include?(row["allowed"])
          raise AuthorizedResource::AuthorizationTransportError,
            "authorization decision lookup returned an invalid decision"
        end
        key = [row["scope_type"].to_s, row["scope_id"].to_s, row["permission"].to_s]
        target = expected.delete(key)
        unless target && !result.key?(target)
          raise AuthorizedResource::AuthorizationTransportError,
            "authorization decision lookup returned an uncorrelated decision"
        end
        result[target] = row.fetch("allowed")
      end
      unless expected.empty?
        raise AuthorizedResource::AuthorizationTransportError,
          "authorization decision lookup omitted a requested target"
      end
      decisions
    rescue JSON::ParserError => error
      raise AuthorizedResource::AuthorizationTransportError,
        "authorization decision lookup failed: #{error.class}"
    end

    def post(uri, scope_ids)
      post_json(uri, scope_id: scope_ids)
    end

    def post_json(uri, payload)
      request = Net::HTTP::Post.new(uri)
      AuthorizationContext.transport_headers.each { |key, value| request[key] = value }
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      OpenTelemetry.propagation.inject(request)
      request.body = JSON.generate(payload)
      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 30
      ) { |http| http.request(request) }
    rescue AuthorizationContext::Error, AuthorizedResource::AuthorizationTransportError
      raise
    rescue IOError, SystemCallError, Timeout::Error, SocketError, URI::Error => error
      raise AuthorizedResource::AuthorizationTransportError,
        "authorization lookup failed: #{error.class}"
    end
  end
end
