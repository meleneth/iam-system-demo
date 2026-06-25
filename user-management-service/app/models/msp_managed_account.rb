# frozen_string_literal: true

class MspManagedAccount
  def self.managed_account_ids(msp_account_id)
    account_ids = []
    continuance = nil

    loop do
      page = page(msp_account_id, continuance: continuance)
      ids = page.fetch("managed_account_ids").map(&:to_s)
      account_ids.concat(ids)
      continuance = page["continuance"]
      break if ids.empty? || continuance.blank?
    end

    account_ids
  end

  def self.page(msp_account_id, continuance: nil)
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/msp_managed_accounts/#{msp_account_id}"
    outgoing_headers = { "pad-user-id" => "IAM_SYSTEM" }
    OpenTelemetry.propagation.inject(outgoing_headers)

    params = {}
    params[:continuance] = continuance if continuance.present?

    response = Faraday.get(url, params) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get MSP managed accounts for #{msp_account_id}: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body)
  end

  def self.manager_for(managed_account_id)
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/msp_managed_accounts/managed/#{managed_account_id}"
    outgoing_headers = { "pad-user-id" => "IAM_SYSTEM" }
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.get(url) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get MSP manager for #{managed_account_id}: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body, symbolize_names: true)
  end
end
