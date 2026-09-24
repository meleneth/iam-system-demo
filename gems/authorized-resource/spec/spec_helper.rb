# frozen_string_literal: true

require "authorized_resource"
require "opentelemetry/sdk"

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.around do |example|
    AuthorizationContext.without { example.run }
  end

  config.after do
    AuthorizedModel.reset_configuration!
  end
end
