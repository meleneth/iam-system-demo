require "minitest/autorun"
require "net/http"
require "stringio"
require "rack/mock"
require "action_controller"
require "opentelemetry/instrumentation/rack"
require "puma"
require "puma/server"
require "opentelemetry/sdk"

class PhaseController < ActionController::API
  before_action do
    OpenTelemetry.tracer_provider.tracer("test").in_span("authorization.callback") { }
  end

  def show
    render json: { actor: request.headers["pad-user-id"], body: request.raw_post, baggage: OpenTelemetry::Baggage.value("test.baggage") }
  end

  def fail_action
    raise "controller failure"
  end
end

class TraceServerIntegrationTest < Minitest::Test
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |c|
    c.use "OpenTelemetry::Instrumentation::Rack", { use_rack_events: false }
    c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER))
  end

  def setup
    @exporter = EXPORTER
    @exporter.reset
    @errors = []
    OpenTelemetry.error_handler = ->(**details) { @errors << details }
  end

  def teardown
    assert_empty @errors, "OpenTelemetry reported instrumentation errors"
  end

  def test_real_puma_keepalive_requests_have_connected_api_spans_without_controller_phases
    app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(PhaseController.action(:show))
    server = Puma::Server.new(app, Puma::Events.new, min_threads: 1, max_threads: 1)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.binder.ios.first.addr[1]
    server.run
    Net::HTTP.start("127.0.0.1", port) do |http|
      2.times do |i|
        request = Net::HTTP::Post.new("/")
        request["traceparent"] = "00-#{'a' * 32}-#{'b' * 16}-01"
        request["pad-user-id"] = "real-actor-#{i}"
        request["baggage"] = "test.baggage=value-#{i}"
        request.body = "payload-#{i}"
        response = http.request(request)
        assert_equal "200", response.code
        assert_equal({ "actor" => "real-actor-#{i}", "body" => "payload-#{i}", "baggage" => "value-#{i}" }, JSON.parse(response.body))
      end
    end
    server.stop(true)
    spans = @exporter.finished_spans
    servers = spans.select { |span| span.kind == :server }
    assert_equal 2, servers.size
    assert_equal 2, spans.count { |span| span.name == "authorization.callback" }
    assert_equal 4, spans.size
    servers.each do |span|
      assert_equal ['b' * 16].pack("H*"), span.parent_span_id
      assert_equal ['a' * 32].pack("H*"), span.trace_id
      assert spans.any? { |child| child.name == "authorization.callback" && child.parent_span_id == span.span_id }
    end
    refute OpenTelemetry::Trace.current_span.context.valid?
  ensure
    server&.stop(true)
  end

  def test_controller_exception_is_preserved_and_context_detached
    app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(PhaseController.action(:fail_action))
    error = assert_raises(RuntimeError) { app.call(Rack::MockRequest.env_for("/", "HTTP_TRACEPARENT" => "00-#{'a' * 32}-#{'b' * 16}-01")) }
    assert_equal "controller failure", error.message
    assert_equal 2, @exporter.finished_spans.size
    server = @exporter.finished_spans.find { |span| span.kind == :server }
    assert_equal OpenTelemetry::Trace::Status::ERROR, server.status.code
    refute OpenTelemetry::Trace.current_span.context.valid?
  end
end
