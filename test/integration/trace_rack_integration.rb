require "rack"
require "rack/events"
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/rack"
exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::Rack"
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
end
require_relative "../../account-service/lib/rack_phases"
body = Class.new do
  attr_reader :closed
  def each; yield "abc"; yield "de"; end
  def close; @closed = true; end
end.new
app = Rack::Events.new(->(_env) { [200, {"content-type" => "text/plain"}, body] },
  [OpenTelemetry::Instrumentation::Rack::Middlewares::EventHandler.new])
response = Rack::MockRequest.new(app).get("/")
raise "response changed" unless response.status == 200 && response.body == "abcde" && body.closed
spans = exporter.finished_spans
server = spans.find { |s| s.kind == :server }
emit = spans.find { |s| s.name == "rack.response.commit_to_close" }
raise "emission parent missing" unless server && emit && emit.parent_span_id == server.span_id
raise "lifecycle events missing" unless server.events.map(&:name) == %w[rack.application.entry rack.response.ready rack.response.body.enumeration.begin rack.response.closed]
raise "emission outside server" unless emit.end_timestamp <= server.end_timestamp
raise "context leaked" if OpenTelemetry::Trace.current_span.context.valid?
puts "Installed Rack Events integration: emission, lifecycle events, body closing and context preserved"
