require "minitest/autorun"
require "net/http"
require "stringio"
require "rack/mock"
require "action_controller"
require_relative "../../account-service/lib/rack_phases"
require "puma"
require "puma/server"
require "opentelemetry/sdk"
require_relative "../../account-service/lib/controller_phases"

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
    c.use "OpenTelemetry::Instrumentation::Rack"
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

  def test_real_puma_keepalive_requests_have_controller_boundaries
    app = Rack::Events.new(PhaseController.action(:show), [OpenTelemetry::Instrumentation::Rack::Middlewares::EventHandler.new])
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
    racks = spans.select { |s| s.kind == :server }
    assert_equal 2, racks.length
    racks.each do |rack|
      assert_equal ['b' * 16].pack("H*"), rack.parent_span_id
      assert_equal ['a' * 32].pack("H*"), rack.trace_id
      controller = spans.find { |s| s.parent_span_id == rack.span_id && s.name == "PhaseController#show" }
      refute_nil controller
      callback = spans.find { |s| s.name == "authorization.callback" && s.parent_span_id == controller.span_id }
      refute_nil callback
      assert_operator callback.start_timestamp, :>=, controller.start_timestamp
      assert_operator controller.end_timestamp, :<=, rack.end_timestamp
    end
    refute OpenTelemetry::Trace.current_span.context.valid?
  ensure
    server&.stop(true)
  end

  def test_controller_exception_is_preserved_and_context_detached
    error = assert_raises(RuntimeError) { PhaseController.action(:fail_action).call(Rack::MockRequest.env_for("/")) }
    assert_equal "controller failure", error.message
    span = @exporter.finished_spans.find { |s| s.name == "PhaseController#fail_action" }
    refute_nil span
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    refute OpenTelemetry::Trace.current_span.context.valid?
  end

  def test_controller_tracing_can_be_disabled
    previous = ENV["IAM_TRACE_CONTROLLER_PHASES"]
    ENV["IAM_TRACE_CONTROLLER_PHASES"] = "false"
    response = PhaseController.action(:show).call(Rack::MockRequest.env_for("/"))
    assert_equal 200, response[0]
    refute @exporter.finished_spans.any? { |s| s.name == "PhaseController#show" }
  ensure
    ENV["IAM_TRACE_CONTROLLER_PHASES"] = previous
  end
end
