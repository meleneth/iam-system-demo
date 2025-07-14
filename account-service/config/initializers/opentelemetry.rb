require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"


OpenTelemetry::SDK.configure do |c|
  otel_endpoint =  "#{ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")}/v1/traces"
  c.service_name = "account-service"
  c.use_all
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: otel_endpoint)
    )
  )
end
