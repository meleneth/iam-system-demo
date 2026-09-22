# frozen_string_literal: true

module AuthorizedResource
  module Evaluator
    module_function

    def authorize!(resource_class, kind, records, operation: kind, requirements: nil)
      policy = resource_class.authorization_policy
      ensure_policy!(resource_class, policy, kind)
      records = Array(records).flatten.compact
      return records if records.empty?

      context = AuthorizationContext.current!
      if context.iam?
        allowed = kind == :read ? policy.iam_readers : policy.iam_modifiers
        unless allowed.include?(context.iam_identity)
          raise AuthorizationDenied, "#{context.iam_identity} is not authorized for #{resource_class.name} #{operation}"
        end
        return records
      end

      requirements ||= kind == :read ? policy.read_requirements : policy.modify_requirements
      if requirements.empty?
        raise AuthorizationDenied, "requesting users are not authorized for #{resource_class.name} #{operation}"
      end
      alternatives = records.to_h do |record|
        [record, requirements.flat_map { |requirement| requirement.targets(record) }.uniq]
      end
      if alternatives.any? { |_record, targets| targets.empty? }
        raise PolicyConfigurationError,
          "#{resource_class.name} #{kind} policy could not resolve an authorization target"
      end

      targets = alternatives.values.flatten.uniq
      Instrumentation.trace_authorization(resource_class, operation, records, targets) do
        capabilities = AuthorizedResource.authorization_client.capabilities(targets)
        denied = alternatives.any? do |_record, record_targets|
          record_targets.none? do |target|
            capabilities.fetch(target.scope_type, {}).fetch(target.scope_id, []).include?(target.capability)
          end
        end
        raise AuthorizationDenied, "authorization denied for #{resource_class.name} #{operation}" if denied
      end
      records
    end

    def ensure_policy!(resource_class, policy, kind)
      unless policy.configured_for?(kind)
        raise PolicyConfigurationError, "#{resource_class.name} has no explicit #{kind} authorization policy"
      end
      if kind == :modify && policy.read_only?
        raise ReadOnlyError, "#{resource_class.name} is explicitly read-only"
      end
    end
  end
end
