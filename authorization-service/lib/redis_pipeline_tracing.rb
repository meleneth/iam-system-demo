# frozen_string_literal: true

require 'redis'

# One span per real Redis pipeline. Standalone commands and connection setup
# are deliberately untraced; key/value lists do not belong in the waterfall.
module RedisPipelineTracing
  def call_pipelined(commands, redis_config)
    return super if commands.empty? || !OpenTelemetry::Trace.current_span.context.valid?

    operations = commands.map { |command| command.first.to_s.upcase }.tally
    return super if operations.keys.all? { |operation| %w[HELLO AUTH SELECT CLIENT].include?(operation) }
    summary = operations.map { |operation, count| "#{count} #{operation}" }.join(', ')
    attributes = {
      'db.system' => 'redis',
      'db.operation.name' => 'PIPELINED',
      'db.redis.database_index' => redis_config.db,
      'db.redis.pipeline.command_count' => commands.size,
      'db.redis.pipeline.commands' => summary,
      'net.peer.name' => redis_config.host,
      'net.peer.port' => redis_config.port
    }
    OpenTelemetry.tracer_provider.tracer('iam.redis_pipeline').in_span(
      "Redis pipeline: #{summary}", attributes: attributes, kind: :client
    ) { super }
  end
end

RedisClient.register(RedisPipelineTracing)
