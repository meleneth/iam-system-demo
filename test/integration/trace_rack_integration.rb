require "rack"
require "rack/events"
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/rack"
exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::Rack", { use_rack_events: false }
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
end
body = Class.new do
  attr_reader :closed
  def each; yield "abc"; yield "de"; end
  def close; @closed = true; end
end.new
app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(->(_env) { [200, {"content-type" => "text/plain"}, body] })
response = Rack::MockRequest.new(app).get("/")
raise "response changed" unless response.status == 200 && response.body == "abcde" && body.closed
spans = exporter.finished_spans
raise "API span missing" unless spans.size == 1 && spans.first.kind == :server
raise "context leaked" if OpenTelemetry::Trace.current_span.context.valid?
puts "Rack API span: body closing and context preserved without lifecycle phase spans"
