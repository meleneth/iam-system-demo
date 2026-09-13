# Run with the application's bundled gems (does not boot Rails or need databases).
require "minitest/autorun"
require "opentelemetry/sdk"
require "socket"
require "net/http"
require "graphql"
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
