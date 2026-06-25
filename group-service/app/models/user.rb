# frozen_string_literal: true

class User
  def self.user_can(user_id, scope_type, permission, scope_id)
    scope_ids = Array(scope_id)
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

  def self.msp_reflected_user_can_manage_users?(user_id:, msp_account_id:, account_ids:)
    ids = Array(account_ids).map(&:to_s)
    return true if ids.empty?

    url = "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/msp_reflected_user_grants/check"
    outgoing_headers = {
      "pad-user-id" => user_id,
      "Content-Type" => "application/json"
    }
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.post(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
      req.body = {
        user_id: user_id,
        msp_account_id: msp_account_id,
        account_ids: ids
      }.to_json
    end

    return false unless response.status == 200

    body = JSON.parse(response.body, symbolize_names: true)
    return false if body[:loading]

    (ids - Array(body[:authorized_account_ids]).map(&:to_s)).empty?
  end
end
