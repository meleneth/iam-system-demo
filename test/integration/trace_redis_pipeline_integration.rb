require 'minitest/autorun'
require 'securerandom'
require 'opentelemetry/sdk'
require_relative '../../account-service/lib/redis_pipeline_tracing'

class RedisPipelineTraceTest < Minitest::Test
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |c|
    c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER))
  end

  def test_only_real_pipelines_are_traced_and_results_are_unchanged
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://accountcache:6379/15'))
    keys = 2.times.map { "trace-test:#{SecureRandom.uuid}" }
    EXPORTER.reset
    OpenTelemetry.tracer_provider.tracer('test').in_span('request') do
      assert_equal 'OK', redis.set(keys.first, 'first')
      assert_equal 'first', redis.get(keys.first)
      assert_equal ['first', nil], redis.pipelined { |pipe| keys.each { |key| pipe.get(key) } }
      assert_equal ['OK', 'second'], redis.pipelined { |pipe| pipe.set(keys.last, 'second'); pipe.get(keys.last) }
    end
    spans = EXPORTER.finished_spans
    assert_equal 3, spans.size
    pipelines = spans.select { |span| span.attributes['db.system'] == 'redis' }
    assert_equal ['Redis pipeline: 2 GET', 'Redis pipeline: 1 SET, 1 GET'], pipelines.map(&:name)
    request = spans.find { |span| span.name == 'request' }
    pipelines.each do |span|
      assert_equal request.span_id, span.parent_span_id
      assert_equal 2, span.attributes['db.redis.pipeline.command_count']
      assert_equal 'PIPELINED', span.attributes['db.operation.name']
      refute span.attributes.key?('db.statement')
    end
  ensure
    redis&.del(*keys) if keys
    redis&.close
  end

  def test_service_copies_stay_in_sync
    root = File.expand_path('../..', __dir__)
    copies = Dir[File.join(root, '*-service/lib/redis_pipeline_tracing.rb')].map { |path| File.read(path) }
    assert_equal 3, copies.size
    assert_equal 1, copies.uniq.size
  end
end
