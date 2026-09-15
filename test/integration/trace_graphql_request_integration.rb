# Run in the user-management test container with the repository mounted at /workspace.
require 'minitest/autorun'
require_relative '../../user-management-service/config/environment'

class GraphqlRequestTraceTest < Minitest::Test
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry.tracer_provider.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)
  )

  def test_graphql_document_is_on_the_actual_http_server_span
    [
      ['{ __typename }', nil],
      ["query InspectTrace {\n  __typename\n}", 'InspectTrace']
    ].each do |query, operation_name|
      EXPORTER.reset
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! 'localhost'
      session.post('/graphql', params: {query: query, operationName: operation_name}, as: :json,
        headers: {'traceparent' => "00-#{'a' * 32}-#{'b' * 16}-01"})
      assert_equal 200, session.response.status
      assert_equal 'Query', session.response.parsed_body.fetch('data').fetch('__typename')
      span = EXPORTER.finished_spans.find { |candidate| candidate.kind == :server }
      refute_nil span
      assert_equal query, span.attributes['graphql.document']
      assert_equal(operation_name ? "GraphQL #{operation_name}" : 'GraphQL', span.name)
      if operation_name
        assert_equal operation_name, span.attributes['graphql.operation.name']
      else
        refute span.attributes.key?('graphql.operation.name')
      end
      assert_equal ['a' * 32].pack('H*'), span.trace_id
      assert_equal ['b' * 16].pack('H*'), span.parent_span_id
    end
  end
end
