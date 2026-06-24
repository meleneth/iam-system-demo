# frozen_string_literal: true

class MspReflectedUserGrant
  def self.check(user_id:, msp_account_id:, account_ids:)
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
        account_ids: account_ids
      }.to_json
    end

    raise "MSP reflected grant check failed: #{response.status} #{response.body}" unless [200, 202].include?(response.status)

    JSON.parse(response.body, symbolize_names: true)
  end
end
