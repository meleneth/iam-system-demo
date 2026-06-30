# frozen_string_literal: true

require "faraday"

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
end
