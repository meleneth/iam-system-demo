require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  otel_endpoint =  "#{ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")}/v1/traces"
  c.service_name = "user-management-service"
  c.use_all({
    "OpenTelemetry::Instrumentation::GraphQL" => {
      enable_platform_field: false,       # per-field/resolver spans
      enable_platform_authorized: false,  # (optional)
      enable_platform_resolve_type: true # (optional)
    }
  })
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: otel_endpoint)
    )
  )
end
