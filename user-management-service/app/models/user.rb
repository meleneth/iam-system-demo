# frozen_string_literal: true
require "json"

# app/models/user.rb
class User < RemoteResource
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL", "http://user-service:80")
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "users"

  # Optional: handle nested resources, errors, etc.
 
  def can(scope_type, permission, scope_id)
    context = AuthorizationContext.current!
    scope_ids = Array(scope_id).map(&:to_s).uniq
    return true if scope_ids.empty?
    if id == "IAM_SYSTEM"
      raise AuthorizationContext::InvalidContextError, "IAM actor requires IAM scope" unless context.iam? && context.iam_identity == id
      return true
    end
    raise AuthorizationContext::InvalidContextError, "authorization actor mismatch" unless context.user_id == id.to_s
    return capabilities_authorize?(scope_type, permission, scope_ids) if self.class.capabilities_mode?

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

  def capabilities_authorize?(scope_type, permission, scope_ids)
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

  def self.users_count(account_ids)
    AuthorizationContext.current!
    account_ids = Array(account_ids)

    url = "#{Env::USER_SERVICE_API_BASE_URL}/accounts/users/counts"

    outgoing_headers = headers.dup
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { account_id: account_ids }.to_json
    end

    raise ActiveResource::ForbiddenAccess.new(response) if response.status == 403
    raise "Error getting Account's User counts" unless response.status == 200

    JSON.parse(response.body, symbolize_names: true)
  end

  def self.search(params)
    AuthorizationContext.current!
    raw = connection.post(
      "/users/search",
      params.to_json,
      headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
    )

    decoded = ActiveSupport::JSON.decode(raw.body)

    decoded.map { |attrs| new(attrs) }
  end
end
