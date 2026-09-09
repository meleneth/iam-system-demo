require "minitest/autorun"
require_relative "../scripts/benchmark_environment"

class BenchmarkEnvironmentTest < Minitest::Test
  def test_default_benchmarks_target_production
    old = ENV.delete("BENCHMARK_STACK")
    values = BenchmarkEnvironment.values
    assert_equal "./dc_prod", values.fetch("BENCHMARK_WRAPPER")
    assert_equal "production", values.fetch("RAILS_ENV")
    assert_equal "http://localhost:7501", values.fetch("USER_MANAGEMENT_BASE_URL")
    assert_equal "http://localhost:11360", values.fetch("ACCOUNT_SERVICE_BASE_URL")
    assert_equal "http://localhost:11290", values.fetch("JAEGER_BASE_URL")
    assert_includes values.fetch("MANIFEST"), "data/production/"
    ENV["BENCHMARK_STACK"] = "dev"
    assert_equal "./dc_dev", BenchmarkEnvironment.values.fetch("BENCHMARK_WRAPPER")
  ensure
    ENV["BENCHMARK_STACK"] = old
  end
end
