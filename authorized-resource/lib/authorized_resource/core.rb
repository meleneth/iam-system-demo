# frozen_string_literal: true

require "authorization_context"
require "opentelemetry-api"

require_relative "errors"
require_relative "policy"
require_relative "authorization_client"
require_relative "instrumentation"
require_relative "operation"
require_relative "evaluator"

module AuthorizedResource
  class << self
    attr_writer :authorization_service_url, :authorization_client

    def authorization_service_url
      @authorization_service_url || ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL")
    end

    def authorization_client
      @authorization_client ||= AuthorizationClient.new(base_url: authorization_service_url)
    end

    def reset_configuration!
      @authorization_service_url = nil
      @authorization_client = nil
    end
  end
end
