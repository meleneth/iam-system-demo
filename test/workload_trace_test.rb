require 'minitest/autorun'
require_relative '../scripts/workload_trace'
require_relative '../scripts/refresh_article_traces'

class WorkloadTraceTest < Minitest::Test
  def test_exports_measured_root_with_typed_intent_metadata_and_failure_status
    sent = nil
    trace = WorkloadTrace.new(endpoint: 'http://unused', name: 'Load users | can | Redis cold | batched 200',
      attributes: {'retrieval.batch_size' => 200, 'redis.enabled' => true, 'fixture.name' => 'wide_org'},
      sender: ->(payload) { sent = payload })
    stopped = trace.stop
    trace.export(trace_id: 'a' * 32, span_id: 'b' * 16, outcome: 'transport_error')
    resource = sent.fetch(:resourceSpans).first
    assert_equal 'trace-workloads', resource.fetch(:resource).fetch(:attributes).first.fetch(:value).fetch(:stringValue)
    span = resource.fetch(:scopeSpans).first.fetch(:spans).first
    assert_equal 'a' * 32, span.fetch(:traceId)
    assert_equal 'b' * 16, span.fetch(:spanId)
    refute span.key?(:parentSpanId)
    assert_equal stopped.to_s, span.fetch(:endTimeUnixNano)
    assert_operator span.fetch(:endTimeUnixNano).to_i, :>=, span.fetch(:startTimeUnixNano).to_i
    assert_equal 2, span.fetch(:status).fetch(:code)
    attributes = span.fetch(:attributes).to_h { |entry| [entry[:key], entry[:value]] }
    assert_equal({intValue: '200'}, attributes.fetch('retrieval.batch_size'))
    assert_equal({boolValue: true}, attributes.fetch('redis.enabled'))
    assert_equal({stringValue: 'transport_error'}, attributes.fetch('workload.outcome'))
  end

  def test_names_distinguish_intent_configuration_and_cache_phase
    collector = ArticleTraceRefresh.allocate
    collector.instance_variable_set(:@case, {'id' => 'graphql-cache-b200', 'auth' => 'can', 'redis' => 'true', 'retrieval' => 'batched', 'batch_size' => 200})
    collector.instance_variable_set(:@out, '/tmp/example')
    collector.instance_variable_set(:@revision, 'revision')
    collector.instance_variable_set(:@seed_profile, 'limited')
    collector.instance_variable_set(:@stack_env, {'BENCHMARK_STACK' => 'prod', 'OTEL_COLLECTOR_BASE_URL' => 'http://unused'})
    fixture = {'name' => 'massive_fanout_10k', 'user_count' => 10_000, 'account_count' => 10_000}
    trace = collector.send(:workload_trace, 'graphql-msp', fixture)
    assert_equal 'GraphQL MSP users and groups | limited/massive_fanout_10k (10000 users) | can | Redis warm | batched 200', trace.instance_variable_get(:@name)
    cold = collector.send(:workload_trace, 'graphql-cold', fixture)
    assert_includes cold.instance_variable_get(:@name), 'Redis cold'
    warmup = collector.send(:workload_trace, 'warmup-1', fixture)
    assert warmup.instance_variable_get(:@name).start_with?('Warmup: ')
    assert_equal true, warmup.instance_variable_get(:@attributes).fetch('workload.warmup')
  end
end
