# frozen_string_literal: true

require "rack/events"
require "opentelemetry/instrumentation/rack"
require "opentelemetry/instrumentation/rack/middlewares/event_handler"

# The bundled Rack instrumentation uses Rack::Events, not TracerMiddleware.
# Extend those lifecycle callbacks without wrapping/replacing response bodies.
module RackPhases
  module EventHandler
    def on_start(request, response)
      super
      span = OpenTelemetry::Instrumentation::Rack.current_span
      return unless span.recording?

      request.env["iam.rack.started"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      span.add_event("rack.application.entry")
    end

    def on_commit(request, response)
      super
      started = request.env["iam.rack.started"]
      return unless started

      OpenTelemetry::Instrumentation::Rack.current_span.add_event("rack.response.ready", attributes: {
        "phase.elapsed_ms" => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      })
      # Puma can consume Array bodies without calling each/on_send. Measure
      # the supported commit-to-close interval for every body representation.
      phase = OpenTelemetry.tracer_provider.tracer("iam.rack_phases").start_span("rack.response.commit_to_close")
      request.env["iam.rack.emission"] = [phase, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
    end

    def on_send(request, response)
      super
      return unless request.env["iam.rack.started"]

      OpenTelemetry::Instrumentation::Rack.current_span.add_event("rack.response.body.enumeration.begin")
    end

    def on_finish(request, response)
      if (emission = request.env.delete("iam.rack.emission"))
        span, started = emission
        span.set_attribute("phase.elapsed_ms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
        span.finish
      end
      OpenTelemetry::Instrumentation::Rack.current_span.add_event("rack.response.closed") if request.env.delete("iam.rack.started")
    ensure
      # The upstream handler finishes the server span and detaches its context.
      super
    end
  end
end

OpenTelemetry::Instrumentation::Rack::Middlewares::EventHandler.prepend(RackPhases::EventHandler)
