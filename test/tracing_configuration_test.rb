require "minitest/autorun"
require "yaml"

class TracingConfigurationTest < Minitest::Test
  def test_authorization_account_role_preserves_the_account_environment
    services = YAML.unsafe_load_file(File.expand_path("../compose/account-service.yml", __dir__)).fetch("services")
    normal = services.fetch("account-service").fetch("environment")
    auth = services.fetch("account-auth-service").fetch("environment")
    assert_equal "account-auth-service", auth.fetch("OTEL_SERVICE_NAME")
    assert_equal "authorization-account-lookup", auth.fetch("IAM_DEPLOYMENT_ROLE")
    assert_equal normal, auth.reject { |key, _| %w[OTEL_SERVICE_NAME IAM_DEPLOYMENT_ROLE].include?(key) }
  end

  def test_rack_events_are_loaded_before_sdk_selects_the_middleware_backend
    Dir[File.expand_path("../*-service/config/initializers/opentelemetry.rb", __dir__)].each do |path|
      source = File.read(path)
      assert_operator source.index('require_relative "../../lib/rack_phases"'), :<, source.index("OpenTelemetry::SDK.configure")
      boot = File.read(File.expand_path("../boot.rb", File.dirname(path)))
      assert_includes boot, 'require_relative "../lib/rack_phases"'
    end
  end

  def test_phase_hooks_are_identical_in_isolated_service_build_contexts
    %w[http_phases.rb rack_phases.rb].each do |name|
      copies = Dir[File.expand_path("../*-service/lib/#{name}", __dir__)]
      assert_equal 6, copies.size
      assert_equal 1, copies.map { |path| File.read(path) }.uniq.size
    end
  end
end
