# frozen_string_literal: true

module AuthorizedResource
  module Instrumentation
    module_function

    def trace(resource_class, operation)
      attributes = {
        "authorized_resource.type" => resource_class.name.to_s,
        "authorized_resource.operation" => operation.to_s,
        "server.address" => service_name(resource_class)
      }
      tracer.in_span("authorized_resource.#{resource_class.name}.#{operation}", attributes: attributes) do |span|
        result = yield span
        span.set_attribute("authorized_resource.outcome", "ok")
        result
      rescue AuthorizationDenied => error
        span.set_attribute("authorized_resource.outcome", "denied")
        raise error
      rescue AuthorizationContext::MissingContextError => error
        span.set_attribute("authorized_resource.outcome", "missing_context")
        raise error
      rescue AuthorizationTransportError => error
        span.set_attribute("authorized_resource.outcome", "authorization_transport_error")
        raise error
      rescue PolicyConfigurationError => error
        span.set_attribute("authorized_resource.outcome", "policy_configuration_error")
        raise error
      rescue ReadOnlyError => error
        span.set_attribute("authorized_resource.outcome", "read_only")
        raise error
      rescue StandardError => error
        resource_transport = defined?(ActiveResource::ConnectionError) && error.is_a?(ActiveResource::ConnectionError)
        span.set_attribute("authorized_resource.outcome", resource_transport ? "resource_transport_error" : "error")
        raise error
      end
    end

    def trace_authorization(resource_class, operation, records, targets)
      attributes = {
        "authorized_resource.type" => resource_class.name.to_s,
        "authorized_resource.operation" => operation.to_s,
        "authorization.scope_types" => targets.map(&:scope_type).uniq.sort.join(","),
        "authorization.batch_size" => records.size
      }
      tracer.in_span("authorized_resource.authorize", attributes: attributes) do |span|
        result = yield span
        span.set_attribute("authorized_resource.outcome", "ok")
        result
      rescue AuthorizationDenied => error
        span.set_attribute("authorized_resource.outcome", "denied")
        raise error
      rescue AuthorizationTransportError => error
        span.set_attribute("authorized_resource.outcome", "transport_error")
        raise error
      end
    end

    def tracer
      OpenTelemetry.tracer_provider.tracer("authorized-resource", AuthorizedResource::VERSION)
    end

    def service_name(resource_class)
      resource_class.site&.host.to_s
    rescue StandardError
      ""
    end
  end
end
