# frozen_string_literal: true

module AuthorizationContext
  module ActiveRecordProtection
    module RelationProtection
      %i[exec_queries calculate pluck pick ids exists?].each do |method_name|
        define_method(method_name) do |*args, **kwargs, &block|
          AuthorizationContext.current!
          super(*args, **kwargs, &block)
        end
      end

      def load_async
        raise InvalidContextError, "protected asynchronous retrieval requires explicit context propagation"
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      private

      # Extend every relation at construction time so `unscoped` cannot remove
      # the guard as it could remove a default scope.
      def relation
        super.extending(RelationProtection)
      end

      public

      def find_by_sql(...)
        AuthorizationContext.current!
        super
      end

      def count_by_sql(...)
        AuthorizationContext.current!
        super
      end
    end
  end
end
