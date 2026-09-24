# frozen_string_literal: true

module AuthorizedResource
  # ActiveResource boundary that requires an existing AuthorizationContext,
  # propagates it per request, and traces logical remote operations. Capability
  # evaluation belongs exclusively to the receiving service.
  class Base < ActiveResource::Base
    CLASS_OPERATIONS = {
      build: [:read, "build"],
      find: [:read, "find"],
      exists?: [:read, "exists"],
      delete: [:modify, "delete"],
      get: [:read, "custom_get"],
      post: [:modify, "custom_post"],
      put: [:modify, "custom_put"],
      patch: [:modify, "custom_patch"]
    }.freeze

    INSTANCE_OPERATIONS = {
      destroy: [:modify, "destroy"],
      exists?: [:read, "exists"],
      reload: [:read, "reload"],
      get: [:read, "custom_get"],
      post: [:modify, "custom_post"],
      put: [:modify, "custom_put"],
      patch: [:modify, "custom_patch"],
      delete: [:modify, "custom_delete"]
    }.freeze

    class << self
      def connection(refresh = false)
        ConnectionProxy.new(super, self)
      end

      # Build fresh headers for every operation. Never put actor metadata in
      # ActiveResource's shared class header hash or its pooled connection.
      def headers
        operation_headers = super.merge(AuthorizationContext.transport_headers)
        OpenTelemetry.propagation.inject(operation_headers)
        operation_headers.freeze
      end

      CLASS_OPERATIONS.each do |method_name, (kind, operation)|
        define_method(method_name) do |*args, **kwargs, &block|
          public_send("authorized_#{kind}", operation) { super(*args, **kwargs, &block) }
        end
      end

      # Custom endpoints use these wrappers to provide semantic operation names,
      # especially for POST-based reads and cache-backed retrievals.
      def authorized_read(logical_operation)
        perform_remote_operation(logical_operation) { yield }
      end

      def authorized_modify(logical_operation)
        perform_remote_operation(logical_operation) { yield }
      end

      private

      def perform_remote_operation(logical_operation)
        Operation.within(self, logical_operation) do |span, outermost|
          result = yield
          span&.set_attribute("authorized_resource.batch_size", result.size) if outermost && result.is_a?(Array)
          result
        end
      end
    end

    def save
      self.class.authorized_modify(new? ? "create" : "update") { super }
    end

    INSTANCE_OPERATIONS.each do |method_name, (kind, operation)|
      define_method(method_name) do |*args, **kwargs, &block|
        self.class.public_send("authorized_#{kind}", operation) { super(*args, **kwargs, &block) }
      end
    end
  end
end
