# frozen_string_literal: true

require "active_support/lazy_load_hooks"

# Prepend to the concrete controller bases so the interval includes their
# process_action callbacks, authorization, action, and rendering.
module ControllerPhases
  def process_action(action, ...)
    return super unless ENV.fetch("IAM_TRACE_CONTROLLER_PHASES", "true") == "true"

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    OpenTelemetry.tracer_provider.tracer("iam.controller_phases").in_span(
      "#{self.class.name}##{action}",
      attributes: { "code.namespace" => self.class.name, "code.function" => action.to_s }
    ) do |span|
      begin
        super
      ensure
        span.set_attribute("phase.elapsed_ms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      end
    end
  end
end

ActiveSupport.on_load(:action_controller_base) { prepend ControllerPhases }
ActiveSupport.on_load(:action_controller_api) { prepend ControllerPhases }
