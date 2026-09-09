# frozen_string_literal: true
require "shellwords"

# Resolve the wrapper, fixture paths and published ports from one stack selection.
module BenchmarkEnvironment
  def self.values
    stack = ENV.fetch("BENCHMARK_STACK", "prod")
    environment = { "prod" => "production", "dev" => "development" }.fetch(stack) { raise "BENCHMARK_STACK must be prod or dev" }
    path = "#{environment}.env"
    settings = File.exist?(path) ? File.readlines(path).filter_map { |line|
      key, value = line.strip.split("=", 2)
      [key, value] if value && !key.start_with?("#")
    }.to_h : {}
    port = ->(key, fallback) { ENV.fetch(key) { settings.fetch(key, fallback) } }
    defaults = stack == "prod" ? %w[7501 11360 11290 11280] : %w[7500 11230 11160 11150]
    result = { "BENCHMARK_STACK" => stack, "BENCHMARK_WRAPPER" => "./dc_#{stack}",
      "BENCHMARK_ENV_FILE" => path, "RAILS_ENV" => environment,
      "MANIFEST" => "data/#{environment}/demo-fixtures/latest/fixture_manifest.json" }
    %w[USER_MANAGEMENT ACCOUNT_SERVICE JAEGER GRAFANA].zip(defaults).each do |name, fallback|
      key = name == "ACCOUNT_SERVICE" ? "ACCOUNT_SERVICE_WEB_PORT" : "#{name}_WEB_PORT"
      result["#{name}_BASE_URL"] = "http://localhost:#{port.call(key, fallback)}"
    end
    %w[GLOBAL_IAM_DEMO_USE_REDIS AUTHORIZATION_CHECK_MODE IAM_DEMO_BATCH_SIZE IAM_DEMO_RETRIEVAL_MODE].each do |key|
      result[key] = settings[key] if settings[key]
    end
    result.merge(ENV.to_h.slice(*result.keys.reject { |key| %w[BENCHMARK_WRAPPER BENCHMARK_ENV_FILE RAILS_ENV].include?(key) }))
  end
end

if $PROGRAM_NAME == __FILE__
  BenchmarkEnvironment.values.each { |key, value| puts "export #{key}=#{Shellwords.escape(value)}" }
end
