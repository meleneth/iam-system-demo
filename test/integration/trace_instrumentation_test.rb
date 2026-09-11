# Run with the application's bundled gems (does not boot Rails or need databases).
require "minitest/autorun"
require "opentelemetry/sdk"
require "socket"
require "net/http"
require "graphql"
require_relative "../../account-service/lib/http_phases"
require_relative "../../account-service/lib/rack_phases"
require_relative "../../user-management-service/app/graphql/tracing/source_context"
require_relative "../../user-management-service/app/graphql/tracing/dataloader"

class TraceInstrumentationTest < Minitest::Test
  class Source < GraphQL::Dataloader::Source
    def initialize(otel_ctx:)
      @otel_ctx = otel_ctx
    end

    def fetch(ids)
      OpenTelemetry::Context.with_current(@otel_ctx) do
        OpenTelemetry.tracer_provider.tracer("test").in_span("source.fetch") { ids }
      end
    end
  end

  class Query < GraphQL::Schema::Object
    field :values, [Integer], null: false
    def values
      dataloader.with(Source, otel_ctx: context[:otel_ctx]).load_all([1, 2])
    end
  end

  module MultiplexTrace
    def execute_multiplex(**)
      OpenTelemetry.tracer_provider.tracer("test").in_span("graphql.execute_multiplex") { super }
    end
  end

  class Schema < GraphQL::Schema
    query Query
    use Tracing::Dataloader
    trace_with MultiplexTrace
    trace_with Tracing::SourceContext
  end

  def setup
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    @provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
    OpenTelemetry.tracer_provider = @provider
    @tracer = @provider.tracer("test")
  end

  def teardown
    @provider.shutdown
  end

  def test_http_phases_preserve_body_headers_context_and_connection_reuse
    listener = TCPServer.new("127.0.0.1", 0)
    requests = []
    server = Thread.new do
      socket = listener.accept
      2.times do
        headers = +""
        headers << socket.gets until headers.end_with?("\r\n\r\n")
        length = headers[/Content-Length: (\d+)/i, 1].to_i
        requests << [headers, socket.read(length)]
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}")
      end
      socket.close
    end
    @tracer.in_span("caller") do
      Net::HTTP.start("127.0.0.1", listener.addr[1], nil) do |http|
        2.times do
          req = Net::HTTP::Post.new("/organization_account_ids/for_account_ids")
          req["pad-user-id"] = "real-actor"
          req.body = '{"account_ids":["a"]}'
          assert_equal "{}", http.request(req).body
        end
      end
    end
    server.value
    spans = @exporter.finished_spans
    %w[http.connection.connect http.connection.prepare http.request.write http.response.headers.wait_and_read http.response.body.read].each do |name|
      phase = spans.find { |span| span.name == name }
      refute_nil phase, name
      assert_operator phase.attributes.fetch("phase.elapsed_ms"), :>=, 0
      assert_equal spans.find { |s| s.name == "caller" }.span_id, phase.parent_span_id
    end
    assert_equal 1, spans.count { |s| s.name == "http.connection.connect" }
    assert_equal [false, true], spans.select { |s| s.name == "http.connection.prepare" }.map { |s| s.attributes["http.connection.reused"] }
    assert requests.all? { |headers, body| headers.include?("Pad-User-Id: real-actor") && body == '{"account_ids":["a"]}' }
  ensure
    listener&.close
    server&.kill if server&.alive?
  end

  def test_disabled_http_phases_preserve_return_value_without_spans
    previous = ENV["IAM_TRACE_HTTP_PHASES"]
    ENV["IAM_TRACE_HTTP_PHASES"] = "false"
    @tracer.in_span("caller") do
      assert_equal :result, HttpPhases.trace("disabled.phase") { :result }
    end
    assert_equal ["caller"], @exporter.finished_spans.map(&:name)
  ensure
    previous.nil? ? ENV.delete("IAM_TRACE_HTTP_PHASES") : ENV["IAM_TRACE_HTTP_PHASES"] = previous
  end

  def test_phase_errors_propagate_and_record_duration
    assert_raises(IOError) do
      @tracer.in_span("caller") { HttpPhases.trace("failing.phase") { raise IOError, "test failure" } }
    end
    phase = @exporter.finished_spans.find { |span| span.name == "failing.phase" }
    assert_operator phase.attributes.fetch("phase.elapsed_ms"), :>=, 0
    assert_equal OpenTelemetry::Trace::Status::ERROR, phase.status.code
  end

  def test_sources_are_children_of_live_multiplex_and_requests_do_not_leak_context
    2.times do
      @tracer.in_span("rack") do
        result = Schema.execute("{ values }", context: { otel_ctx: OpenTelemetry::Context.current })
        assert_equal [1, 2], result.to_h.fetch("data").fetch("values")
        assert_equal "rack", OpenTelemetry::Trace.current_span.name
      end
    end
    spans = @exporter.finished_spans
    sources = spans.select { |s| s.name == "source.fetch" }
    assert_equal 2, sources.size
    sources.each do |source|
      parent = spans.find { |s| s.span_id == source.parent_span_id }
      assert_equal "graphql.execute_multiplex", parent.name
      assert_equal source.trace_id, parent.trace_id
    end
    assert_equal 2, sources.map(&:trace_id).uniq.size
  end
end
