# frozen_string_literal: true

class MspManagedAccount
  DEFAULT_LIMIT = 5_000

  def self.managed_account_ids(msp_account_id, limit: DEFAULT_LIMIT)
    account_ids = []
    offset = 0
    total_count = nil

    loop do
      page = page(msp_account_id, offset: offset, limit: limit)
      total_count ||= page.fetch("total_count").to_i
      ids = page.fetch("managed_account_ids").map(&:to_s)
      account_ids.concat(ids)
      offset += ids.length
      break if ids.empty? || account_ids.length >= total_count
    end

    account_ids
  end

  def self.page(msp_account_id, offset:, limit:)
    url = "#{Env::ORGANIZATION_SERVICE_API_BASE_URL}/internal/msp_managed_accounts/#{msp_account_id}"
    outgoing_headers = { "pad-user-id" => "IAM_SYSTEM" }
    OpenTelemetry.propagation.inject(outgoing_headers)

    response = Faraday.get(url, { offset: offset, limit: limit }) do |req|
      outgoing_headers.each { |key, value| req.headers[key] = value }
    end

    raise "Failed to get MSP managed accounts for #{msp_account_id}: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body)
  end
end
