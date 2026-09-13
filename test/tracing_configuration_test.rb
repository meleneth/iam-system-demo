require "minitest/autorun"
require "yaml"

class TracingConfigurationTest < Minitest::Test
  def test_authorization_account_role_preserves_the_account_environment
    services = YAML.unsafe_load_file(File.expand_path("../compose/account-service.yml", __dir__)).fetch("services")
    normal = services.fetch("account-service").fetch("environment")
    auth = services.fetch("account-auth-service").fetch("environment")
    assert_equal "account-auth-service", auth.fetch("OTEL_SERVICE_NAME")
    assert_equal "authorization-account-lookup", auth.fetch("IAM_DEPLOYMENT_ROLE")
    assert_equal "http://organization-auth-service:80", auth.fetch("ORGANIZATION_SERVICE_API_BASE_URL")
    assert_equal normal.reject { |key, _| key == "ORGANIZATION_SERVICE_API_BASE_URL" }, auth.reject { |key, _| %w[OTEL_SERVICE_NAME IAM_DEPLOYMENT_ROLE ORGANIZATION_SERVICE_API_BASE_URL].include?(key) }
  end

  def test_group_and_organization_fact_roles_share_ownership_without_host_ports
    %w[group organization].each do |domain|
      services = YAML.unsafe_load_file(File.expand_path("../compose/#{domain}-service.yml", __dir__)).fetch("services")
      normal = services.fetch("#{domain}-service")
      auth = services.fetch("#{domain}-auth-service")
      env = auth.fetch("environment").to_h { |entry| entry.split("=", 2) }
      assert_equal "#{domain}-auth-service", env.fetch("OTEL_SERVICE_NAME")
      assert_equal "authorization-#{domain}-lookup", env.fetch("IAM_DEPLOYMENT_ROLE")
      assert_empty auth.fetch("ports")
      assert_equal normal.fetch("environment"), auth.fetch("environment").reject { |entry| entry.start_with?("OTEL_SERVICE_NAME=", "IAM_DEPLOYMENT_ROLE=") }
      prod = YAML.unsafe_load_file(File.expand_path("../production-overrides.yml", __dir__)).fetch("services")
      assert_equal prod.fetch("#{domain}-service").fetch("environment"), prod.fetch("#{domain}-auth-service").fetch("environment")
    end
  end

  def test_http_cache_and_graphql_allowlist_and_application_sql_are_enabled
    paths = Dir[File.expand_path("../*-service/config/initializers/opentelemetry.rb", __dir__)]
    assert_equal 6, paths.size
    paths.each do |path|
      source = File.read(path)
      names = source.scan(/c.use "([^"]+)"/).flatten
      assert_empty names - %w[OpenTelemetry::Instrumentation::Net::HTTP OpenTelemetry::Instrumentation::Rack OpenTelemetry::Instrumentation::Redis OpenTelemetry::Instrumentation::GraphQL]
      assert_includes names, "OpenTelemetry::Instrumentation::Net::HTTP"
      assert_includes names, "OpenTelemetry::Instrumentation::Rack"
      assert_includes names, "OpenTelemetry::Instrumentation::Redis"
      refute_includes source, "c.use_all"
      assert_includes source, "ApplicationSqlTracing.install"
    end
  end

  def test_sql_helpers_are_identical_in_isolated_service_build_contexts
    %w[application_sql_tracing http_request_tracing].each do |name|
      copies = Dir[File.expand_path("../*-service/lib/#{name}.rb", __dir__)]
      assert_equal 6, copies.size
      assert_equal 1, copies.map { |path| File.read(path) }.uniq.size
    end
    assert_empty Dir[File.expand_path("../*-service/lib/*_phases.rb", __dir__)]
  end
  def test_solid_cache_is_removed_but_active_record_query_cache_is_preserved
    Dir[File.expand_path("../*-service/Gemfile", __dir__)].each do |path|
      refute_includes File.read(path), 'gem "solid_cache"'
      service = File.dirname(path)
      assert_includes File.read(File.join(service, "config/environments/production.rb")), "config.cache_store = :null_store"
      refute_includes File.read(File.join(service, "config/database.yml")), "query_cache: false"
    end
  end

end
