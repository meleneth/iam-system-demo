require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"
require "socket"
require "net/http"
require_relative "../../lib/application_sql_tracing"

OpenTelemetry::SDK.configure do |c|
  otel_endpoint =  "#{ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")}/v1/traces"
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "user-management-service")
  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    "service.instance.id" => "#{Socket.gethostname}:#{Process.pid}",
    "deployment.role" => ENV.fetch("IAM_DEPLOYMENT_ROLE", "web"),
    "process.pid" => Process.pid
  )
  # One HTTP client span covers direct, Faraday, and ActiveResource requests.
  c.use "OpenTelemetry::Instrumentation::Net::HTTP"
  c.use "OpenTelemetry::Instrumentation::Rack", { use_rack_events: false, untraced_endpoints: ["/up"] }
  c.use "OpenTelemetry::Instrumentation::Redis"
  c.use "OpenTelemetry::Instrumentation::GraphQL", {
    enable_platform_field: false,
    enable_platform_authorized: false,
    enable_platform_resolve_type: false
  }
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: otel_endpoint)
    )
  )
end

ApplicationSqlTracing.install
Rails.application.config.middleware.insert_before 0, *OpenTelemetry::Instrumentation::Rack::Instrumentation.instance.middleware_args
