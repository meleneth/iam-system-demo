require "opentelemetry/sdk"
require "opentelemetry/instrumentation/graphql"
require "graphql"
exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::GraphQL", { enable_platform_field: false, enable_platform_authorized: false, enable_platform_resolve_type: false }
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
end
require_relative "../../user-management-service/app/graphql/tracing/source_context"
require_relative "../../user-management-service/app/graphql/tracing/dataloader"
class ActualSource < GraphQL::Dataloader::Source
  def initialize(ctx:); @ctx = ctx; end
  def fetch(ids)
    OpenTelemetry::Context.with_current(@ctx) { OpenTelemetry.tracer_provider.tracer("probe").in_span("source.fetch") { ids } }
  end
end
class ActualQuery < GraphQL::Schema::Object
  field :ids, [Integer], null: false
  def ids; dataloader.with(ActualSource, ctx: context[:otel_ctx]).load_all([1, 2]); end
end
class ActualSchema < GraphQL::Schema
  query ActualQuery
  trace_with Tracing::SourceContext
  use Tracing::Dataloader
end
OpenTelemetry.tracer_provider.tracer("probe").in_span("rack") do
  raise unless ActualSchema.execute("{ ids }", context: {otel_ctx: OpenTelemetry::Context.current}).to_h == {"data" => {"ids" => [1, 2]}}
end
spans = exporter.finished_spans
source = spans.find { |s| s.name == "source.fetch" }
parent = spans.find { |s| s.span_id == source.parent_span_id }
raise "wrong source parent: #{parent&.name}" unless parent&.name == "graphql.execute_multiplex"
puts "Installed OTel GraphQL integration: source.fetch parent = #{parent.name}"
