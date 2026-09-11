require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"
require "socket"
# Rack selects its backend during SDK installation; load Events first.
require_relative "../../lib/rack_phases"

OpenTelemetry::SDK.configure do |c|
  otel_endpoint =  "#{ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")}/v1/traces"
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "user-management-service")
  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    "service.instance.id" => "#{Socket.gethostname}:#{Process.pid}",
    "deployment.role" => ENV.fetch("IAM_DEPLOYMENT_ROLE", "web"),
    "process.pid" => Process.pid
  )
  c.use_all({
    "OpenTelemetry::Instrumentation::Faraday" => { enable_internal_instrumentation: true },
    "OpenTelemetry::Instrumentation::GraphQL" => {
      enable_platform_field: false,       # per-field/resolver spans
      enable_platform_authorized: false,  # (optional)
      enable_platform_resolve_type: false # (optional)
    }
  })
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: otel_endpoint)
    )
  )
end

require_relative "../../lib/http_phases"

require_relative "../../lib/controller_phases"
