# frozen_string_literal: true

require "active_support"
require "active_support/isolated_execution_state"

module AuthorizationContext
  STORAGE_KEY = :iam_demo_authorization_context
  IAM_IDENTITIES = %w[IAM_SYSTEM IAM_SYSTEM_AUTH].freeze

  class Error < StandardError; end
  class MissingContextError < Error; end
  class InvalidContextError < Error; end

  Context = Data.define(:actor_id) do
    def iam?
      IAM_IDENTITIES.include?(actor_id)
    end

    def requesting_user?
      !iam?
    end

    def user_id
      actor_id if requesting_user?
    end

    def iam_identity
      actor_id if iam?
    end

    def to_h
      {actor_id: actor_id}.freeze
    end
  end

  class << self
    def as_iam(identity: "IAM_SYSTEM", &block)
      raise ArgumentError, "block required" unless block
      identity = required_string!(identity, :identity)
      raise InvalidContextError, "unsupported IAM identity" unless IAM_IDENTITIES.include?(identity)

      activate(Context.new(actor_id: identity), &block)
    end

    def as_requesting_user(user_id:, &block)
      raise ArgumentError, "block required" unless block
      user_id = required_string!(user_id, :user_id)
      raise InvalidContextError, "IAM identities are not requesting users" if IAM_IDENTITIES.include?(user_id)

      activate(Context.new(actor_id: user_id), &block)
    end

    def current
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY]
    end

    def current!
      current || raise(MissingContextError, "protected retrieval requires an explicit authorization context")
    end

    def capture
      current!
    end

    def with(context, &block)
      raise InvalidContextError, "invalid captured context" unless context.is_a?(Context)
      raise ArgumentError, "block required" unless block

      activate(normalize_context(context), &block)
    end

    def without(&block)
      raise ArgumentError, "block required" unless block

      activate(nil, &block)
    end

    def transport_headers(context = current!)
      {"pad-user-id" => context.actor_id}.freeze
    end

    def from_headers(headers)
      Context.new(actor_id: required_string!(header(headers, "pad-user-id"), :actor_id))
    end

    def within_request(headers, &block)
      with(from_headers(headers), &block)
    end

    private

    def activate(context)
      previous = current
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = context&.freeze
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = previous
    end

    def normalize_context(context)
      Context.new(actor_id: required_string!(context.actor_id, :actor_id))
    end

    def required_string!(value, name)
      value = value.to_s.strip
      raise InvalidContextError, "#{name} is required" if value.empty?
      value.freeze
    end

    def header(headers, name)
      headers[name] || headers[name.downcase] || headers["HTTP_#{name.upcase.tr('-', '_')}"]
    end
  end
end
