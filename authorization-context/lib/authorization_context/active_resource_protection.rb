# frozen_string_literal: true

module AuthorizationContext
  module ActiveResourceProtection
    HTTP_METHODS = %i[get head delete post put patch].freeze

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def connection(refresh = false)
        ConnectionProxy.new(super, -> { AuthorizationContext.transport_headers })
      end

      def headers
        super.merge(AuthorizationContext.transport_headers).freeze
      end
    end

    class ConnectionProxy
      def initialize(connection, headers)
        @connection = connection
        @headers = headers
        freeze
      end

      HTTP_METHODS.each do |method_name|
        define_method(method_name) do |*args, **kwargs, &block|
          context_headers = @headers.call
          header_index = method_name == :post || method_name == :put || method_name == :patch ? 2 : 1
          supplied = args[header_index].is_a?(Hash) ? args[header_index] : {}
          args[header_index] = supplied.merge(context_headers)
          @connection.public_send(method_name, *args, **kwargs, &block)
        end
      end

      def method_missing(name, *args, **kwargs, &block)
        @connection.public_send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @connection.respond_to?(name, include_private) || super
      end
    end
  end
end
