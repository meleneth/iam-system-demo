# frozen_string_literal: true

module AuthorizedResource
  class ConnectionProxy
    HTTP_METHODS = %i[get head delete post put patch].freeze

    def initialize(connection, resource_class)
      @connection = connection
      @resource_class = resource_class
      freeze
    end

    HTTP_METHODS.each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        kind = %i[get head].include?(method_name) ? :read : :modify
        Operation.within(@resource_class, "connection_#{method_name}", kind) do
          context_headers = AuthorizationContext.transport_headers
          header_index = %i[post put patch].include?(method_name) ? 2 : 1
          supplied = args[header_index].is_a?(Hash) ? args[header_index] : {}
          args[header_index] = supplied.merge(context_headers)
          @connection.public_send(method_name, *args, **kwargs, &block)
        end
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
