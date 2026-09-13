# Run in the account-service image against its existing database; reads only.
require "minitest/autorun"
require "active_record"
require "opentelemetry/sdk"
require_relative "../../account-service/lib/application_sql_tracing"

class ApplicationSqlTest < Minitest::Test
  class Account < ActiveRecord::Base; end

  def test_application_queries_are_recorded_but_setup_schema_and_query_cache_hits_are_not
    ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    OpenTelemetry.tracer_provider = provider
    ApplicationSqlTracing.install
    target = Account.limit(1).pluck(:id).first
    refute_nil target
    Account.reset_column_information
    cache_hits = 0
    listener = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| cache_hits += 1 if args.last[:cached] }
    pools = ActiveRecord::QueryCache.run
    provider.tracer("test").in_span("API account lookup", kind: :server) do
      Account.column_names
      Account.connection.execute("SET application_name = 'trace_sql_test'")
      Account.connection.select_value("SELECT oid FROM pg_catalog.pg_class LIMIT 1")
      2.times { assert_equal target, Account.where(id: target).to_a.first.id }
    end
    ActiveRecord::QueryCache.complete(pools)
    spans = exporter.finished_spans
    queries = spans.select { |s| s.attributes["db.system"] == "postgresql" }
    assert_equal 1, queries.size
    assert_equal 1, cache_hits
    sql = queries.first
    assert_match(/SELECT .*accounts/i, sql.attributes.fetch("db.statement"))
    assert_equal spans.find { |s| s.name == "API account lookup" }.span_id, sql.parent_span_id
    assert_operator sql.end_timestamp, :>=, sql.start_timestamp
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
    provider&.shutdown
    ActiveRecord::Base.connection_pool.disconnect!
  end
end
