# Real HTTP requests from all three supported clients, through a downstream API.
require "minitest/autorun"
require "net/http"
require "faraday"
require "active_resource"
require "rack"
require "puma"
require "puma/server"
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/net/http"
require "opentelemetry/instrumentation/rack"

class RequestTracingTest < Minitest::Test
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |c|
    c.use "OpenTelemetry::Instrumentation::Net::HTTP"
    c.use "OpenTelemetry::Instrumentation::Rack", { use_rack_events: false }
    c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER))
  end

  class Widget < ActiveResource::Base
    self.format = :json
  end

  def test_direct_faraday_and_active_resource_requests_retain_api_ancestry_and_actor
    EXPORTER.reset
    received = []
    app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(->(env) {
      received << [env["PATH_INFO"], env["HTTP_PAD_USER_ID"], env["rack.input"].read]
      [200, { "content-type" => "application/json" }, ['{"id":1,"name":"widget"}']]
    })
    server = Puma::Server.new(app, Puma::Events.new, min_threads: 1, max_threads: 1)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.binder.ios.first.addr[1]
    server.run
    base = "http://127.0.0.1:#{port}"
    OpenTelemetry.tracer_provider.tracer("test").in_span("application.lookup") do
      assert_equal "200", Net::HTTP.get_response(URI("#{base}/direct"), "pad-user-id" => "real-actor").code
      response = Faraday.post("#{base}/faraday", '{"ids":[1]}', "pad-user-id" => "real-actor")
      assert_equal 200, response.status
      Widget.site = base
      Widget.headers["pad-user-id"] = "real-actor"
      assert_equal "widget", Widget.find(1).name
    end
    server.stop(true)
    spans = EXPORTER.finished_spans
    clients = spans.select { |s| s.kind == :client }
    servers = spans.select { |s| s.kind == :server }
    assert_equal 3, clients.size
    assert_equal 3, servers.size
    root = spans.find { |s| s.name == "application.lookup" }
    clients.each do |client|
      assert_equal root.span_id, client.parent_span_id
      api = servers.find { |s| s.parent_span_id == client.span_id }
      refute_nil api
      assert_equal root.trace_id, api.trace_id
    end
    assert_equal %w[/direct /faraday /widgets/1.json], received.map(&:first)
    assert received.all? { |row| row[1] == "real-actor" }
    assert_equal '{"ids":[1]}', received[1][2]
    refute OpenTelemetry::Trace.current_span.context.valid?
    refute spans.any? { |span| span.name.match?(/http\.(connection|request\.write|response)|Controller#|rack\.response/) }
  ensure
    server&.stop(true)
  end
end
