# frozen_string_literal: true

require "faraday"
require "json"

class User < ApplicationRecord
  include Mel::Filterable

  validates :account_id, presence: true
  filterable_fields :account_id, :id

  def self.user_can?(user_id:, permission:, account_ids:)
    ids = Array(account_ids).map(&:to_s).uniq
    return true if ids.empty?
    return true if user_id == "IAM_SYSTEM"
    return capabilities_authorize?(user_id: user_id, scope_type: "Account", permission: permission, scope_ids: ids) if capabilities_mode?

    response = Faraday.post("#{authorization_service_url}/can/Account/#{permission}") do |req|
      outgoing_headers(user_id).each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: ids }.to_json
    end

    response.status == 200
  end

  def self.capabilities_authorize?(user_id:, scope_type:, permission:, scope_ids:)
    response = Faraday.post("#{authorization_service_url}/capabilities/#{scope_type}") do |req|
      outgoing_headers(user_id).each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: scope_ids }.to_json
    end
    return false unless response.status == 200

    capabilities_by_scope = JSON.parse(response.body)
    scope_ids.all? { |scope_id| Array(capabilities_by_scope[scope_id]).include?(permission) }
  end

  def self.authorization_service_url
    ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  end

  def self.outgoing_headers(user_id)
    { "pad-user-id" => user_id }.tap { |headers| OpenTelemetry.propagation.inject(headers) }
  end

  def self.capabilities_mode?
    ENV.fetch("AUTHORIZATION_CHECK_MODE", "can") == "capabilities"
  end
end
