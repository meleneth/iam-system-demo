# frozen_string_literal: true

require "active_support"
require "active_support/isolated_execution_state"

module AuthorizationContext
  STORAGE_KEY = :iam_demo_authorization_context
  IAM_IDENTITIES = %w[IAM_SYSTEM IAM_SYSTEM_AUTH].freeze

  class Error < StandardError; end
  class MissingContextError < Error; end
  class InvalidContextError < Error; end
  class UnauthenticatedAuthorityError < Error; end

  Context = Data.define(:authority, :user_id, :originating_user_id, :account_id, :organization_id, :iam_identity) do
    def iam?
      authority == :iam
    end

    def requesting_user?
      authority == :requesting_user
    end

    def actor_id
      iam? ? iam_identity : user_id
    end

    def to_h
      {
        authority: authority,
        user_id: user_id,
        originating_user_id: originating_user_id,
        account_id: account_id,
        organization_id: organization_id,
        iam_identity: iam_identity
      }.freeze
    end
  end

  class << self
    def as_iam(originating_user_id: nil, identity: "IAM_SYSTEM", account_id: nil, organization_id: nil, &block)
      raise ArgumentError, "block required" unless block
      identity = required_string!(identity, :identity)
      raise InvalidContextError, "unsupported IAM identity" unless IAM_IDENTITIES.include?(identity)
      originating_user_id ||= current&.originating_user_id

      activate(Context.new(
        authority: :iam,
        user_id: nil,
        originating_user_id: optional_string(originating_user_id),
        account_id: optional_string(account_id),
        organization_id: optional_string(organization_id),
        iam_identity: identity
      ), &block)
    end

    def as_requesting_user(user_id:, account_id: nil, organization_id: nil, &block)
      raise ArgumentError, "block required" unless block
      user_id = required_string!(user_id, :user_id)
      raise InvalidContextError, "IAM identities are not requesting users" if IAM_IDENTITIES.include?(user_id)

      activate(Context.new(
        authority: :requesting_user,
        user_id: user_id,
        originating_user_id: user_id,
        account_id: optional_string(account_id),
        organization_id: optional_string(organization_id),
        iam_identity: nil
      ), &block)
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
      headers = {
        "pad-user-id" => context.actor_id,
        "X-IAM-Authorization-Scope" => context.authority.to_s.tr("_", "-")
      }
      headers["X-IAM-Originating-User-ID"] = context.originating_user_id if context.originating_user_id
      headers["X-IAM-Account-ID"] = context.account_id if context.account_id
      headers["X-IAM-Organization-ID"] = context.organization_id if context.organization_id
      if context.iam?
        token = ENV["IAM_INTERNAL_TOKEN"].to_s
        raise UnauthenticatedAuthorityError, "IAM_INTERNAL_TOKEN is not configured" if token.empty?
        headers["X-IAM-Internal-Token"] = token
      end
      headers.freeze
    end

    def from_headers(headers)
      actor = header(headers, "pad-user-id")
      scope = header(headers, "X-IAM-Authorization-Scope")
      if scope == "iam" || IAM_IDENTITIES.include?(actor)
        authenticate_iam!(header(headers, "X-IAM-Internal-Token"))
        identity = IAM_IDENTITIES.include?(actor) ? actor : "IAM_SYSTEM"
        Context.new(
          authority: :iam,
          user_id: nil,
          originating_user_id: optional_string(header(headers, "X-IAM-Originating-User-ID")),
          account_id: optional_string(header(headers, "X-IAM-Account-ID")),
          organization_id: optional_string(header(headers, "X-IAM-Organization-ID")),
          iam_identity: identity
        )
      else
        user_id = required_string!(actor, :user_id)
        raise InvalidContextError, "invalid authorization scope" unless scope.nil? || scope.empty? || scope == "requesting-user"
        raise InvalidContextError, "IAM identities are not requesting users" if IAM_IDENTITIES.include?(user_id)
        Context.new(
          authority: :requesting_user,
          user_id: user_id,
          originating_user_id: user_id,
          account_id: optional_string(header(headers, "X-IAM-Account-ID")),
          organization_id: optional_string(header(headers, "X-IAM-Organization-ID")),
          iam_identity: nil
        )
      end
    end

    def within_request(headers, &block)
      with(from_headers(headers), &block)
    end

    private

    def activate(context)
      previous = current
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = context.freeze
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[STORAGE_KEY] = previous
    end

    def normalize_context(context)
      case context.authority
      when :requesting_user
        user_id = required_string!(context.user_id, :user_id)
        raise InvalidContextError, "IAM identities are not requesting users" if IAM_IDENTITIES.include?(user_id)
        Context.new(
          authority: :requesting_user,
          user_id: user_id,
          originating_user_id: user_id,
          account_id: optional_string(context.account_id),
          organization_id: optional_string(context.organization_id),
          iam_identity: nil
        )
      when :iam
        identity = required_string!(context.iam_identity, :identity)
        raise InvalidContextError, "unsupported IAM identity" unless IAM_IDENTITIES.include?(identity)
        Context.new(
          authority: :iam,
          user_id: nil,
          originating_user_id: optional_string(context.originating_user_id),
          account_id: optional_string(context.account_id),
          organization_id: optional_string(context.organization_id),
          iam_identity: identity
        )
      else
        raise InvalidContextError, "invalid authorization authority"
      end
    end

    def required_string!(value, name)
      value = value.to_s.strip
      raise InvalidContextError, "#{name} is required" if value.empty?
      value.freeze
    end

    def optional_string(value)
      value = value.to_s.strip
      value.empty? ? nil : value.freeze
    end

    def header(headers, name)
      headers[name] || headers[name.downcase] || headers["HTTP_#{name.upcase.tr('-', '_')}"]
    end

    def authenticate_iam!(provided)
      expected = ENV["IAM_INTERNAL_TOKEN"].to_s
      provided = provided.to_s
      valid = !expected.empty? && expected.bytesize == provided.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(expected, provided)
      raise UnauthenticatedAuthorityError, "IAM authority authentication failed" unless valid
    end
  end
end
