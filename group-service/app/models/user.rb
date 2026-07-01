# frozen_string_literal: true

require "faraday"
require "json"

class User
  def self.user_can(user_id, scope_type, permission, scope_id)
    scope_ids = Array(scope_id).map(&:to_s).uniq
    return true if scope_ids.empty?
    return true if user_id == "IAM_SYSTEM"
    return capabilities_authorize?(user_id, scope_type, permission, scope_ids) if capabilities_mode?

    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/can/#{scope_type}/#{permission}"

    outgoing_headers = { "pad-user-id" => user_id }
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: scope_ids }.to_json
    end

    response.status == 200
  end

  def self.capabilities_authorize?(user_id, scope_type, permission, scope_ids)
    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/#{scope_type}"
    outgoing_headers = { "pad-user-id" => user_id }
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: scope_ids }.to_json
    end
    return false unless response.status == 200

    capabilities_by_scope = JSON.parse(response.body)
    scope_ids.all? { |scope_id| Array(capabilities_by_scope[scope_id]).include?(permission) }
  end

  def self.capabilities_mode?
    ENV.fetch("AUTHORIZATION_CHECK_MODE", "can") == "capabilities"
  end
end
