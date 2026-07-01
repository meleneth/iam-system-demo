# frozen_string_literal: true
require "json"

# app/models/user.rb
class User < ActiveResource::Base
  attr_accessor :authorization_service
  self.site = ENV.fetch("USER_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
  self.format = :json

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "users"

  # Optional: handle nested resources, errors, etc.
  #
  def self.with_headers(temp_headers)
    old_headers = headers.dup
    propagated_headers = temp_headers.dup
    OpenTelemetry.propagation.inject(propagated_headers)
    self.headers.merge!(propagated_headers)
    yield
  ensure
    self.headers.replace(old_headers)
  end

  def can(scope_type, permission, scope_id)
    self.class.user_can(id, scope_type, permission, scope_id)
  end

  def self.user_can(user_id, scope_type, permission, scope_id, extra_headers = {})
    scope_ids = Array(scope_id).map(&:to_s).uniq
    return true if scope_ids.empty?
    return true if user_id == "IAM_SYSTEM"
    return capabilities_authorize?(user_id, scope_type, permission, scope_ids, extra_headers) if capabilities_mode?

    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/can/#{scope_type}/#{permission}"

    outgoing_headers = { "pad-user-id" => user_id }.merge(extra_headers.compact)
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: scope_ids }.to_json
    end

    response.status == 200
  end

  def self.capabilities_authorize?(user_id, scope_type, permission, scope_ids, extra_headers = {})
    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/#{scope_type}"
    outgoing_headers = { "pad-user-id" => user_id }.merge(extra_headers.compact)
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
