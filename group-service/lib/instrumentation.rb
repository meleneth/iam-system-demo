module Instrumentation
  def self.trace(name, attributes: {}, &block)
    safe_attrs = attributes.transform_keys(&:to_s)
    tracer = OpenTelemetry.tracer_provider.tracer("group-service")
    tracer.in_span(name, attributes: safe_attrs) do |span|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        block.call(span)
      ensure
        span.set_attribute("phase.elapsed_ms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      end
    end
  end
end
