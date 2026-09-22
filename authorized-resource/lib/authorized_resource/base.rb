# frozen_string_literal: true

module AuthorizedResource
  class Base < ActiveResource::Base
    class_attribute :authorization_policy, instance_writer: false, default: Policy.new

    class << self
      def inherited(subclass)
        super
        subclass.authorization_policy = authorization_policy
      end

      def requires_read_capability(capability, scope_type:, target:, iam: [])
        self.authorization_policy = authorization_policy.with_requirement(
          :read,
          Requirement.new(capability: capability.to_s, scope_type: scope_type.to_s, resolver: resolver_for(target)),
          iam: iam
        )
      end

      def requires_modify_capability(capability, scope_type:, target:, iam: [])
        self.authorization_policy = authorization_policy.with_requirement(
          :modify,
          Requirement.new(capability: capability.to_s, scope_type: scope_type.to_s, resolver: resolver_for(target)),
          iam: iam
        )
      end

      def read_only!(iam: [])
        self.authorization_policy = authorization_policy.read_only(iam: iam)
      end

      def allows_iam_read(*identities)
        self.authorization_policy = authorization_policy.with_iam(:read, identities.flatten)
      end

      def allows_iam_modify(*identities)
        self.authorization_policy = authorization_policy.with_iam(:modify, identities.flatten)
      end

      def connection(refresh = false)
        ConnectionProxy.new(super)
      end

      def headers
        super.merge(AuthorizationContext.transport_headers).freeze
      end

      def find(...)
        authorized_read("find") { super }
      end

      def exists?(id, options = {})
        authorized_read("exists", records: [{ primary_key => id }]) { super }
      end

      def delete(id, options = {})
        authorized_modify("delete", records: [{ primary_key => id }]) { super }
      end

      def get(custom_method_name, options = {})
        authorized_read("custom_get") { super }
      end

      def post(*)
        raise UnsupportedOperationError, "class POST is ambiguous; wrap it in authorized_read or authorized_modify"
      end

      def put(*)
        raise UnsupportedOperationError, "class PUT requires an explicit authorized_modify target"
      end

      def patch(*)
        raise UnsupportedOperationError, "class PATCH requires an explicit authorized_modify target"
      end

      def authorization_requirement(capability, scope_type:, target:)
        Requirement.new(capability: capability.to_s, scope_type: scope_type.to_s, resolver: resolver_for(target))
      end

      def authorized_read(logical_operation, records: nil, result_records: nil, requirements: nil, &block)
        perform_authorized(:read, logical_operation, records: records, result_records: result_records,
          requirements: requirements, &block)
      end

      def authorized_modify(logical_operation, records:, result_records: nil, requirements: nil, &block)
        perform_authorized(:modify, logical_operation, records: records, result_records: result_records,
          requirements: requirements, &block)
      end

      def authorize_records!(kind, records, operation: kind, requirements: nil)
        records = Evaluator.authorize!(self, kind, records, operation: operation, requirements: requirements)
        if kind == :read
          records.each do |record|
            record.__send__(:mark_authorized_snapshot!) if record.respond_to?(:mark_authorized_snapshot!, true)
          end
        end
        records
      end

      private

      def perform_authorized(kind, logical_operation, records:, result_records:, requirements:)
        Evaluator.ensure_policy!(self, authorization_policy, kind)
        Operation.within(self, logical_operation, kind) do |span, outermost|
          next yield unless outermost

          authorize_records!(kind, records, operation: logical_operation, requirements: requirements) if records
          result = yield
          resolved = if result_records
            result_records.call(result)
          elsif records.nil?
            result
          end
          authorized = authorize_records!(kind, resolved, operation: logical_operation,
            requirements: requirements) unless resolved.nil?
          span&.set_attribute("authorized_resource.batch_size", Array(authorized).compact.size) if authorized
          result
        end
      end

      def resolver_for(target)
        return target if target.respond_to?(:call)

        lambda do |record|
          if record.respond_to?(target)
            record.public_send(target)
          elsif record.respond_to?(:[])
            record[target] || record[target.to_s]
          end
        end
      end
    end

    def save
      result = self.class.authorized_modify(new? ? "create" : "update", records: mutation_authorization_records) { super }
      mark_authorized_snapshot! if result
      result
    end

    def destroy
      self.class.authorized_modify("destroy", records: mutation_authorization_records) { super }
    end

    def get(method_name, options = {})
      self.class.authorized_read("custom_get", records: [self]) { super }
    end

    def post(method_name, options = {}, body = nil)
      self.class.authorized_modify("custom_post", records: mutation_authorization_records) { super }
    end

    def put(method_name, options = {}, body = "")
      self.class.authorized_modify("custom_put", records: mutation_authorization_records) { super }
    end

    def patch(method_name, options = {}, body = "")
      self.class.authorized_modify("custom_patch", records: mutation_authorization_records) { super }
    end

    def delete(method_name, options = {})
      self.class.authorized_modify("custom_delete", records: mutation_authorization_records) { super }
    end

    private

    def mutation_authorization_records
      previous = instance_variable_get(:@authorized_resource_original_attributes)
      [previous, self].compact
    end

    def mark_authorized_snapshot!
      @authorized_resource_original_attributes = attributes.deep_dup.freeze
      self
    end
  end
end
