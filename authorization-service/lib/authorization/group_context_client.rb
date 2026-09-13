# frozen_string_literal: true

require "json"
require "net/http"

module Authorization
  class GroupContextClient
    def initialize(base_url: ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-auth-service:80"))
      @base_url = base_url
    end

    def group_ids_for(user_id)
      request("memberships", user_id: user_id).fetch("memberships").map { |row| row.fetch("group_id").to_s }.uniq
    end

    def user_ids_for(group_ids)
      request("memberships", group_ids: group_ids).fetch("memberships").map { |row| row.fetch("user_id").to_s }.uniq.sort
    end

    def groups(group_ids)
      request("group_contexts", group_ids: group_ids).fetch("groups")
    end

    private

    def request(path, payload)
      uri = URI.join(@base_url, "/internal/auth/#{path}")
      request = Net::HTTP::Post.new(uri)
      request["pad-user-id"] = "IAM_SYSTEM_AUTH"
      request["Content-Type"] = "application/json"
      OpenTelemetry.propagation.inject(request)
      request.body = JSON.generate(payload)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
      raise "group-service auth lookup failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end
  end
end
