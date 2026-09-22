# frozen_string_literal: true

require "active_record"
require_relative "authorized_resource/core"
require_relative "authorized_resource/policy"
require_relative "authorized_resource/authorization_client"
require_relative "authorized_resource/evaluator"

module AuthorizedModel
  class << self
    attr_writer :authorization_service_url, :authorization_client

    def authorization_service_url
      @authorization_service_url || ENV.fetch("AUTHORIZATION_SERVICE_API_BASE_URL")
    end

    def authorization_client
      @authorization_client ||= AuthorizationClient.new(base_url: authorization_service_url)
    end

    def reset_configuration!
      @authorization_service_url = nil
      @authorization_client = nil
    end
  end

  module RelationProtection
    def exec_queries(...)
      model.authorized_read("query") { super }
    end

    %i[calculate pluck pick ids exists?].each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        if AuthorizedResource::Operation.current&.resource_class == model
          super(*args, **kwargs, &block)
        else
          model.authorized_aggregate(method_name) { super(*args, **kwargs, &block) }
        end
      end
    end

    def load_async
      raise AuthorizationContext::InvalidContextError,
        "protected asynchronous retrieval requires explicit context propagation"
    end
  end

  class Base < ActiveRecord::Base
    self.abstract_class = true
    class_attribute :authorization_policy, instance_writer: false, default: Policy.new

    class << self
      def inherited(subclass)
        super
        subclass.authorization_policy = authorization_policy
      end

      def requires_read_capability(capability, scope_type:, target:, iam: [])
        self.authorization_policy = authorization_policy.with_requirement(
          :read,
          Requirement.new(
            capability: capability.to_s,
            scope_type: scope_type.to_s,
            resolver: resolver_for(target)
          ),
          iam: iam
        )
      end

      def requires_modify_capability(capability, scope_type:, target:, iam: [])
        self.authorization_policy = authorization_policy.with_requirement(
          :modify,
          Requirement.new(
            capability: capability.to_s,
            scope_type: scope_type.to_s,
            resolver: resolver_for(target)
          ),
          iam: iam
        )
      end

      def allows_iam_read(*identities)
        self.authorization_policy = authorization_policy.with_iam(:read, identities.flatten)
      end

      def allows_iam_modify(*identities)
        self.authorization_policy = authorization_policy.with_iam(:modify, identities.flatten)
      end

      def read_only!(iam: [])
        self.authorization_policy = authorization_policy.read_only(iam: iam)
      end

      def authorization_requirement(capability, scope_type:, target:)
        Requirement.new(
          capability: capability.to_s,
          scope_type: scope_type.to_s,
          resolver: resolver_for(target)
        )
      end

      def authorize_records!(kind, records, operation: kind, requirements: nil)
        result = Evaluator.authorize!(self, kind, records, operation: operation,
          requirements: requirements)
        if kind == :read
          result.each { |record| record.__send__(:mark_authorized_snapshot!) if record.respond_to?(:mark_authorized_snapshot!, true) }
        end
        result
      end

      def authorized_read(logical_operation, records: nil, requirements: nil)
        perform_authorized(:read, logical_operation, records: records, requirements: requirements) { yield }
      end

      def authorized_modify(logical_operation, records:, requirements: nil)
        perform_authorized(:modify, logical_operation, records: records, requirements: requirements) { yield }
      end

      def authorized_aggregate(logical_operation)
        Evaluator.ensure_policy!(self, authorization_policy, :read)
        context = AuthorizationContext.current!
        unless context.iam? && authorization_policy.iam_readers.include?(context.iam_identity)
          raise AuthorizedResource::UnsupportedOperationError,
            "#{name}.#{logical_operation} needs an explicit authorized_read target"
        end
        AuthorizedResource::Operation.within(self, logical_operation, :read) { yield }
      end

      def authorized_internal_read(logical_operation, identities:)
        context = AuthorizationContext.current!
        unless context.iam? && Array(identities).map(&:to_s).include?(context.iam_identity)
          raise AuthorizedResource::AuthorizationDenied,
            "#{context.actor_id} is not allowed to perform #{name} #{logical_operation}"
        end
        AuthorizedResource::Operation.within(self, logical_operation, :read) { yield }
      end

      def find_by_sql(...)
        authorized_read("find_by_sql") { super }
      end

      def count_by_sql(...)
        authorized_aggregate("count_by_sql") { super }
      end

      private

      def relation
        super.extending(RelationProtection)
      end

      def perform_authorized(kind, logical_operation, records:, requirements:)
        Evaluator.ensure_policy!(self, authorization_policy, kind)
        AuthorizedResource::Operation.within(self, logical_operation, kind) do |span, outermost|
          next yield unless outermost

          authorize_records!(kind, records, operation: logical_operation, requirements: requirements) if records
          result = yield
          authorized = authorize_records!(kind, result, operation: logical_operation,
            requirements: requirements) if kind == :read && records.nil?
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

    around_create :authorize_model_create
    around_update :authorize_model_update
    around_destroy :authorize_model_destroy

    private

    def authorize_model_create
      self.class.authorized_modify("create", records: [self]) { yield }.tap { mark_authorized_snapshot! }
    end

    def authorize_model_update
      self.class.authorized_modify("update", records: mutation_authorization_records) { yield }.tap { mark_authorized_snapshot! }
    end

    def authorize_model_destroy
      self.class.authorized_modify("destroy", records: mutation_authorization_records) { yield }
    end

    def mark_authorized_snapshot!
      @authorized_model_original_attributes = attributes.deep_dup.freeze
      self
    end

    def mutation_authorization_records
      [@authorized_model_original_attributes, self].compact
    end
  end
end
