# frozen_string_literal: true

require "faraday"

class User < ApplicationRecord
  include Mel::Filterable

  validates :account_id, presence: true
  filterable_fields :account_id, :id

  def self.user_can?(user_id:, permission:, account_ids:)
    ids = Array(account_ids).map(&:to_s).uniq
    return true if ids.empty?

    response = Faraday.post("#{authorization_service_url}/can/Account/#{permission}") do |req|
      outgoing_headers(user_id).each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = { scope_id: ids }.to_json
    end

    response.status == 200
  end

  def self.authorization_service_url
    ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  end

  def self.outgoing_headers(user_id)
    { "pad-user-id" => user_id }.tap { |headers| OpenTelemetry.propagation.inject(headers) }
  end
end
