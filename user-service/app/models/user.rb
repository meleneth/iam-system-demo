# frozen_string_literal: true

require "faraday"

class User < ApplicationRecord
  include Mel::Filterable
  ReflectedAuthCheck = Data.define(:authorized?, :loading?, :status, :loaded_count, :total_count)

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

  def self.msp_reflected_user_manage_users_check(user_id:, msp_account_id:, account_ids:)
    ids = Array(account_ids).map(&:to_s).uniq
    return ReflectedAuthCheck.new(authorized?: true, loading?: false, status: "ready", loaded_count: 0, total_count: 0) if ids.empty?

    response = Faraday.post("#{authorization_service_url}/msp_reflected_user_grants/check") do |req|
      outgoing_headers(user_id).each { |key, value| req.headers[key] = value }
      req.headers["Content-Type"] = "application/json"
      req.body = {
        user_id: user_id,
        msp_account_id: msp_account_id,
        account_ids: ids
      }.to_json
    end

    return ReflectedAuthCheck.new(authorized?: false, loading?: false, status: "failed", loaded_count: 0, total_count: 0) unless [200, 202].include?(response.status)

    body = JSON.parse(response.body, symbolize_names: true)
    loading = body[:loading] || response.status == 202
    return ReflectedAuthCheck.new(authorized?: false, loading?: true, status: body[:status], loaded_count: body[:loaded_count].to_i, total_count: body[:total_count].to_i) if loading

    authorized = (ids - Array(body[:authorized_account_ids]).map(&:to_s)).empty?
    ReflectedAuthCheck.new(authorized?: authorized, loading?: false, status: body[:status], loaded_count: body[:loaded_count].to_i, total_count: body[:total_count].to_i)
  rescue JSON::ParserError
    ReflectedAuthCheck.new(authorized?: false, loading?: false, status: "failed", loaded_count: 0, total_count: 0)
  end

  def self.authorization_service_url
    ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  end

  def self.outgoing_headers(user_id)
    { "pad-user-id" => user_id }.tap { |headers| OpenTelemetry.propagation.inject(headers) }
  end
end
