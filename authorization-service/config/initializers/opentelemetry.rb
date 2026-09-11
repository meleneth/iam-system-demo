require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"
require "socket"
# Rack selects its backend during SDK installation; load Events first.
require_relative "../../lib/rack_phases"


OpenTelemetry::SDK.configure do |c|
  otel_endpoint =  "#{ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318")}/v1/traces"
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "authorization-service")
  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    "service.instance.id" => "#{Socket.gethostname}:#{Process.pid}",
    "deployment.role" => ENV.fetch("IAM_DEPLOYMENT_ROLE", "web"),
    "process.pid" => Process.pid
  )
  c.use_all("OpenTelemetry::Instrumentation::Faraday" => { enable_internal_instrumentation: true })
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: otel_endpoint)
    )
  )
end

require_relative "../../lib/http_phases"
