# frozen_string_literal: true

# Net::HTTP's automatic instrumentation also creates a separate connect span.
# Suppress that phase only; the subsequent API request retains its client span
# and normal trace-context injection.
module HttpRequestTracing
  private

  def annotate_span_with_response!(span, response)
    super
    operation = response&.[]('X-IAM-Trace-Operation')
    span.name = operation if operation && !operation.empty?
  end

  def connect(...)
    OpenTelemetry::Common::Utilities.untraced { super }
  end
end

Net::HTTP.prepend(HttpRequestTracing)
