# frozen_string_literal: true

class MspManagedOrganization
  def self.page(msp_account_id, continuance: nil)
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/msp_managed_organizations/#{msp_account_id}"
    outgoing_headers = { "pad-user-id" => "IAM_SYSTEM" }
    OpenTelemetry.propagation.inject(outgoing_headers)

    params = {}
    params[:continuance] = continuance if continuance.present?

    response = Faraday.get(url, params) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get MSP managed organizations for #{msp_account_id}: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body)
  end
end
