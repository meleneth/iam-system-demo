# config/initializers/env_constants.rb

module Env
  AUTHORIZATION_SERVICE_API_BASE_URL = ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL", "http://authorization-service:80")
  ORGANIZATION_SERVICE_API_BASE_URL = ENV.fetch("ORGANIZATION_SERVICE_API_BASE_URL", "http://organization-service:80")
  USER_SERVICE_API_BASE_URL = ENV.fetch("USER_SERVICE_API_BASE_URL", "http://user-service:80")
  GROUP_SERVICE_API_BASE_URL = ENV.fetch("GROUP_SERVICE_API_BASE_URL", "http://group-service:80")
end
