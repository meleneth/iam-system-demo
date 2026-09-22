# frozen_string_literal: true

module AuthorizedResource
  VERSION = "0.2.0"

  module Operation
    STORAGE_KEY = :iam_demo_authorized_resource_operation
    State = Data.define(:resource_class, :logical_operation, :kind)

    module_function

    def current
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY]
    end

    def within(resource_class, logical_operation, kind)
      existing = current
      return yield(nil, false) if existing&.resource_class == resource_class

      AuthorizationContext.current!
      state = State.new(resource_class: resource_class, logical_operation: logical_operation.to_sym, kind: kind.to_sym).freeze
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = state
      Instrumentation.trace(resource_class, logical_operation) { |span| yield(span, true) }
    ensure
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = existing
    end
  end
end
