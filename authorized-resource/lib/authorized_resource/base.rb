# frozen_string_literal: true

module AuthorizedResource
  # ActiveResource boundary that requires an existing AuthorizationContext,
  # propagates it per request, and traces logical remote operations. Capability
  # evaluation belongs exclusively to the receiving service.
  class Base < ActiveResource::Base
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

      def build(...)
        authorized_read("build") { super }
      end

      def find(...)
        authorized_read("find") { super }
      end

      def exists?(...)
        authorized_read("exists") { super }
      end

      def delete(...)
        authorized_modify("delete") { super }
      end

      def get(...)
        authorized_read("custom_get") { super }
      end

      def post(...)
        authorized_modify("custom_post") { super }
      end

      def put(...)
        authorized_modify("custom_put") { super }
      end

      def patch(...)
        authorized_modify("custom_patch") { super }
      end

      # Custom endpoints use these wrappers to provide semantic operation names,
      # especially for POST-based reads and cache-backed retrievals.
      def authorized_read(logical_operation)
        perform_remote_operation(logical_operation, :read) { yield }
      end

      def authorized_modify(logical_operation)
        perform_remote_operation(logical_operation, :modify) { yield }
      end

      private

      def perform_remote_operation(logical_operation, kind)
        Operation.within(self, logical_operation, kind) do |span, outermost|
          result = yield
          span&.set_attribute("authorized_resource.batch_size", result.size) if outermost && result.is_a?(Array)
          result
        end
      end
    end

    def save
      self.class.authorized_modify(new? ? "create" : "update") { super }
    end

    def destroy
      self.class.authorized_modify("destroy") { super }
    end

    def exists?
      self.class.authorized_read("exists") { super }
    end

    def reload
      self.class.authorized_read("reload") { super }
    end

    def get(...)
      self.class.authorized_read("custom_get") { super }
    end

    def post(...)
      self.class.authorized_modify("custom_post") { super }
    end

    def put(...)
      self.class.authorized_modify("custom_put") { super }
    end

    def patch(...)
      self.class.authorized_modify("custom_patch") { super }
    end

    def delete(...)
      self.class.authorized_modify("custom_delete") { super }
    end
  end
end
