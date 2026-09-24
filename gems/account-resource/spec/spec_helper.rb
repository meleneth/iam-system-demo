# frozen_string_literal: true

require "account_resource"
require "opentelemetry/sdk"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.around { |example| AuthorizationContext.without { example.run } }
end
