# frozen_string_literal: true

module Tracing
  class Dataloader < GraphQL::Dataloader
    def get_fiber_variables
      super.merge(iam_otel_context: OpenTelemetry::Context.current)
    end

    def set_fiber_variables(variables)
      super(variables.reject { |key, _| key == :iam_otel_context })
      @iam_otel_tokens ||= {}.compare_by_identity
      @iam_otel_tokens[Fiber.current] = OpenTelemetry::Context.attach(variables.fetch(:iam_otel_context))
    end

    def cleanup_fiber
      super
    ensure
      token = @iam_otel_tokens&.delete(Fiber.current)
      OpenTelemetry::Context.detach(token) if token
    end
  end
end
