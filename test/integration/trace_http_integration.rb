# Real HTTP requests from all three supported clients, through a downstream API.
require "minitest/autorun"
require "net/http"
require "faraday"
require "authorized_resource"
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

  require_relative "../../account-service/lib/http_request_tracing"

  class Widget < AuthorizedResource::Base
    requires_read_capability "widget.read", scope_type: "Widget", target: :id
    read_only!
    self.format = :json
  end

  def test_direct_faraday_and_authorized_resource_requests_retain_ancestry_and_actor
    EXPORTER.reset
    received = []
    app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(->(env) {
      received << [env["PATH_INFO"], env["HTTP_PAD_USER_ID"], env["rack.input"].read]
      return [403, { "content-type" => "application/json" }, ['{"error":"forbidden"}']] unless env["HTTP_PAD_USER_ID"] == "real-actor"
      [200, { "content-type" => "application/json" }, ['{"id":1,"name":"widget"}']]
    })
    server = Puma::Server.new(app, Puma::Events.new, min_threads: 1, max_threads: 1)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.binder.ios.first.addr[1]
    server.run
    base = "http://127.0.0.1:#{port}"
    client = Object.new
    client.define_singleton_method(:capabilities) do |targets|
      { "Widget" => targets.to_h { |target| [target.scope_id, ["widget.read"]] } }
    end
    previous_client = AuthorizedResource.authorization_client
    AuthorizedResource.authorization_client = client
    OpenTelemetry.tracer_provider.tracer("test").in_span("application.lookup") do
      assert_equal "200", Net::HTTP.get_response(URI("#{base}/direct"), "pad-user-id" => "real-actor").code
      response = Faraday.post("#{base}/faraday", '{"ids":[1]}', "pad-user-id" => "real-actor")
      assert_equal 200, response.status
      Widget.site = base
      AuthorizationContext.as_requesting_user(user_id: "real-actor") do
        assert_equal "widget", Widget.find(1).name
      end
    end
    server.stop(true)
    spans = EXPORTER.finished_spans
    clients = spans.select { |s| s.kind == :client }
    servers = spans.select { |s| s.kind == :server }
    assert_equal 3, clients.size
    assert_equal 3, servers.size
    root = spans.find { |s| s.name == "application.lookup" }
    operation = spans.find { |s| s.name == "authorized_resource.RequestTracingTest::Widget.find" }
    authorization = spans.find { |s| s.name == "authorized_resource.authorize" }
    refute_nil operation
    assert_equal root.span_id, operation.parent_span_id
    assert_equal operation.span_id, authorization.parent_span_id
    clients.each do |client|
      api = servers.find { |s| s.parent_span_id == client.span_id }
      refute_nil api
      assert_equal root.trace_id, api.trace_id
    end
    widget_client = clients.find { |span| spans.any? { |server_span| server_span.parent_span_id == span.span_id && server_span.attributes["url.path"] == "/widgets/1.json" } }
    widget_client ||= clients.find { |span| span.parent_span_id == operation.span_id }
    refute_nil widget_client
    assert_equal operation.span_id, widget_client.parent_span_id
    assert_equal 1, clients.count { |span| span.parent_span_id == operation.span_id }
    assert_equal %w[/direct /faraday /widgets/1.json], received.map(&:first)
    assert received.all? { |row| row[1] == "real-actor" }
    assert_equal '{"ids":[1]}', received[1][2]
    refute OpenTelemetry::Trace.current_span.context.valid?
    refute spans.flat_map { |span| span.attributes.to_a }.flatten.join(" ").include?("real-actor")
    refute spans.any? { |span| span.name.match?(/\Aconnect\z|HTTP CONNECT|http\.(connection|request\.write|response)|Controller#|rack\.response/) }
  ensure
    AuthorizedResource.authorization_client = previous_client if previous_client
    server&.stop(true)
  end
end
