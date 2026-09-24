# frozen_string_literal: true

require "active_record"
require_relative "authorized_resource/core"
require_relative "authorized_resource/authorization_client"

module AuthorizedModel
  Target = Data.define(:scope_type, :scope_id, :capability) do
    def initialize(scope_type:, scope_id:, capability:)
      super(scope_type: scope_type.to_s, scope_id: scope_id.to_s, capability: capability.to_s)
    end
  end

  Requirement = Data.define(:capability, :scope_type, :resolver) do
    def target(record)
      scope_id = resolver.call(record)
      Target.new(scope_type: scope_type, scope_id: scope_id, capability: capability) if scope_id.present?
    end
  end

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
        if AuthorizedResource::Operation.current == model
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
    class_attribute :read_requirement, :modify_requirement, :iam_readers, :iam_modifiers,
      instance_writer: false
    class_attribute :authorization_read_only, instance_writer: false, default: false
    self.read_requirement = nil
    self.modify_requirement = nil
    self.iam_readers = []
    self.iam_modifiers = []

    class << self
      def requires_read_capability(capability, scope_type:, target:, iam: [])
        if read_requirement
          raise AuthorizedResource::PolicyConfigurationError,
            "#{name} already has an explicit read authorization policy"
        end
        self.read_requirement = authorization_requirement(capability, scope_type: scope_type, target: target)
        self.iam_readers = (iam_readers + Array(iam).map(&:to_s)).uniq
      end

      def requires_modify_capability(capability, scope_type:, target:, iam: [])
        if modify_requirement
          raise AuthorizedResource::PolicyConfigurationError,
            "#{name} already has an explicit modify authorization policy"
        end
        self.modify_requirement = authorization_requirement(capability, scope_type: scope_type, target: target)
        self.iam_modifiers = (iam_modifiers + Array(iam).map(&:to_s)).uniq
      end

      def allows_iam_read(*identities)
        self.iam_readers = (iam_readers + identities.flatten.map(&:to_s)).uniq
      end

      def allows_iam_modify(*identities)
        self.iam_modifiers = (iam_modifiers + identities.flatten.map(&:to_s)).uniq
      end

      def read_only!(iam: [])
        self.authorization_read_only = true
        allows_iam_read(*iam)
      end

      def authorization_requirement(capability, scope_type:, target:)
        Requirement.new(
          capability: capability.to_s,
          scope_type: scope_type.to_s,
          resolver: resolver_for(target)
        )
      end

      def authorize_records!(kind, records, operation: kind, requirement: nil)
        ensure_policy!(kind)
        records = Array(records).flatten.compact
        return records if records.empty?

        context = AuthorizationContext.current!
        if context.iam?
          allowed = kind == :read ? iam_readers : iam_modifiers
          unless allowed.include?(context.iam_identity)
            raise AuthorizedResource::AuthorizationDenied,
              "#{context.iam_identity} is not authorized for #{name} #{operation}"
          end
          return records
        end

        requirement ||= kind == :read ? read_requirement : modify_requirement
        raise AuthorizedResource::AuthorizationDenied,
          "requesting users are not authorized for #{name} #{operation}" unless requirement

        targets_by_record = records.to_h { |record| [record, requirement.target(record)] }
        if targets_by_record.any? { |_record, target| target.nil? }
          raise AuthorizedResource::PolicyConfigurationError,
            "#{name} #{kind} policy could not resolve an authorization target"
        end

        targets = targets_by_record.values.uniq
        AuthorizedResource::Instrumentation.trace_authorization(self, operation, records, targets) do
          capabilities = AuthorizedModel.authorization_client.capabilities(targets)
          denied = targets_by_record.any? do |_record, target|
            !capabilities.fetch(target.scope_type, {}).fetch(target.scope_id, []).include?(target.capability)
          end
          raise AuthorizedResource::AuthorizationDenied,
            "authorization denied for #{name} #{operation}" if denied
        end

        result = records
        if kind == :read
          result.each { |record| record.__send__(:mark_authorized_snapshot!) if record.respond_to?(:mark_authorized_snapshot!, true) }
        end
        result
      end

      def authorized_read(logical_operation, records: nil, requirement: nil)
        perform_authorized(:read, logical_operation, records: records, requirement: requirement) { yield }
      end

      def authorized_modify(logical_operation, records:, requirement: nil)
        perform_authorized(:modify, logical_operation, records: records, requirement: requirement) { yield }
      end

      def authorized_aggregate(logical_operation)
        ensure_policy!(:read)
        context = AuthorizationContext.current!
        unless context.iam? && iam_readers.include?(context.iam_identity)
          raise AuthorizedResource::UnsupportedOperationError,
            "#{name}.#{logical_operation} needs an explicit authorized_read target"
        end
        AuthorizedResource::Operation.within(self, logical_operation) { yield }
      end

      def authorized_internal_read(logical_operation, identities:)
        context = AuthorizationContext.current!
        unless context.iam? && Array(identities).map(&:to_s).include?(context.iam_identity)
          raise AuthorizedResource::AuthorizationDenied,
            "#{context.actor_id} is not allowed to perform #{name} #{logical_operation}"
        end
        AuthorizedResource::Operation.within(self, logical_operation) { yield }
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

      def perform_authorized(kind, logical_operation, records:, requirement:)
        ensure_policy!(kind)
        AuthorizedResource::Operation.within(self, logical_operation) do |span, outermost|
          next yield unless outermost

          authorize_records!(kind, records, operation: logical_operation, requirement: requirement) if records
          result = yield
          authorized = authorize_records!(kind, result, operation: logical_operation,
            requirement: requirement) if kind == :read && records.nil?
          span&.set_attribute("authorized_resource.batch_size", Array(authorized).compact.size) if authorized
          result
        end
      end

      def ensure_policy!(kind)
        configured = if kind == :read
          read_requirement || iam_readers.any?
        else
          modify_requirement || iam_modifiers.any? || authorization_read_only
        end
        unless configured
          raise AuthorizedResource::PolicyConfigurationError,
            "#{name} has no explicit #{kind} authorization policy"
        end
        if kind == :modify && authorization_read_only
          raise AuthorizedResource::ReadOnlyError, "#{name} is explicitly read-only"
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
