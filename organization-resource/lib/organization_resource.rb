# frozen_string_literal: true

require "authorized_resource"
require "faraday"
require "json"

class Organization < AuthorizedResource::Base
  self.site = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", "http://organization-service:80")
  self.format = :json
  self.primary_key = "id"
  self.collection_name = "organizations"

  def self.random_internal
    authorized_read("random_internal") do
      response = Faraday.get(endpoint("internal/random/organization")) do |request|
        headers.each { |key, value| request.headers[key] = value }
      end
      unless response.status == 200
        raise "Failed to get random organization: #{response.status} #{response.body}"
      end
      new(JSON.parse(response.body))
    end
  end

  def self.endpoint(path)
    "#{site.to_s.delete_suffix("/")}/#{path.delete_prefix("/")}"
  end
  private_class_method :endpoint

  def accounts
    organization_accounts.map(&:account_id).each_slice(remote_batch_size).flat_map do |ids|
      Account.where(id: ids).to_a
    end
  end

  def organization_accounts
    OrganizationAccount.find(:all, params: {organization_id: id})
  end

  private

  def remote_batch_size
    ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000").to_i.clamp(1, 10_000)
  end
end
