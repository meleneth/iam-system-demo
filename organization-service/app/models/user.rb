# frozen_string_literal: true
require "json"

# app/models/user.rb
class User < RemoteResource
  attr_accessor :authorization_service
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "users"

  # Optional: handle nested resources, errors, etc.
  #
  def can(scope_type, permission, scope_id)
    self.class.user_can(id, scope_type, permission, scope_id)
  end

  def self.user_can(user_id, scope_type, permission, scope_id)
    scope_ids = Array(scope_id).map(&:to_s).uniq
    return true if scope_ids.empty?
    context = AuthorizationContext.current!
    if user_id == "IAM_SYSTEM"
      raise AuthorizationContext::InvalidContextError, "IAM actor requires IAM scope" unless context.iam? && context.iam_identity == user_id
      return true
    end
    raise AuthorizationContext::InvalidContextError, "authorization actor mismatch" unless context.user_id == user_id.to_s
    return capabilities_authorize?(user_id, scope_type, permission, scope_ids) if capabilities_mode?

    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/can/#{scope_type}/#{permission}"

    outgoing_headers = AuthorizationContext.transport_headers.dup
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
    outgoing_headers = AuthorizationContext.transport_headers.dup
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
