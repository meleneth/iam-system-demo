# frozen_string_literal: true

require "authorization_context"
require "opentelemetry-api"

module AuthorizedResource
  VERSION = "0.2.0"

  class Error < StandardError; end
  class PolicyConfigurationError < Error; end
  class UnsupportedOperationError < Error; end
  class ReadOnlyError < Error; end
  class AuthorizationDenied < Error; end
  class AuthorizationTransportError < Error; end

  module Instrumentation
    module_function

    def trace(resource_class, operation)
      attributes = {
        "authorized_resource.type" => resource_class.name.to_s,
        "authorized_resource.operation" => operation.to_s,
        "server.address" => service_name(resource_class)
      }
      tracer.in_span("authorized_resource.#{resource_class.name}.#{operation}", attributes: attributes) do |span|
        yield(span).tap { span.set_attribute("authorized_resource.outcome", "ok") }
      rescue StandardError => error
        span.set_attribute("authorized_resource.outcome", outcome(error))
        raise
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
        yield(span).tap { span.set_attribute("authorized_resource.outcome", "ok") }
      rescue StandardError => error
        span.set_attribute("authorized_resource.outcome", outcome(error, authorization: true))
        raise
      end
    end

    def tracer
      OpenTelemetry.tracer_provider.tracer("authorized-resource", VERSION)
    end

    def outcome(error, authorization: false)
      case error
      when AuthorizationDenied then "denied"
      when AuthorizationTransportError then authorization ? "transport_error" : "authorization_transport_error"
      when AuthorizationContext::MissingContextError then "missing_context"
      when PolicyConfigurationError then "policy_configuration_error"
      when ReadOnlyError then "read_only"
      else
        if defined?(ActiveResource::ConnectionError) && error.is_a?(ActiveResource::ConnectionError)
          "resource_transport_error"
        else
          "error"
        end
      end
    end

    def service_name(resource_class)
      resource_class.site&.host.to_s
    rescue StandardError
      ""
    end
  end

  module Operation
    STORAGE_KEY = :iam_demo_authorized_resource_operation

    module_function

    def current
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY]
    end

    def within(resource_class, logical_operation)
      previous = current
      return yield(nil, false) if previous == resource_class

      AuthorizationContext.current!
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = resource_class
      Instrumentation.trace(resource_class, logical_operation) { |span| yield(span, true) }
    ensure
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = previous
    end
  end
end
