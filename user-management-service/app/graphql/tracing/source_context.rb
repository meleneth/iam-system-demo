# frozen_string_literal: true

module Tracing
  module SourceContext
    def execute_query(query:, **kwargs)
      # Called inside execute_multiplex. Capture this live execution context,
      # once per query, so every source batch shares a stable parent and cache
      # key instead of restoring the controller's pre-execution Rack context.
      query.context[:otel_ctx] = OpenTelemetry::Context.current
      super
    end
  end
end
