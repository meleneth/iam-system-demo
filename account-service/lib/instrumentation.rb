module Instrumentation
  def self.trace(name, attributes: {}, &block)
    safe_attrs = attributes.transform_keys(&:to_s)
    tracer = OpenTelemetry.tracer_provider.tracer("account-service")
    tracer.in_span(name, attributes: safe_attrs, &block)
  end
end
