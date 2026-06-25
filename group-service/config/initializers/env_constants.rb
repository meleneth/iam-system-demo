# frozen_string_literal: true

module Env
  AUTHORIZATION_SERVICE_API_BASE_URL = ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
end
