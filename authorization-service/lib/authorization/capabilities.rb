# frozen_string_literal: true

require "json"

module Authorization
  class Capabilities
    TTL_SECONDS = 300

    def initialize(user_id:, redis: AUTHORIZATION_CACHE)
      @user_id = user_id
      @redis = redis
    end

    def for_organization(organization_id)
      cached(scope_type: "Organization", scope_id: organization_id) do
        CapabilityGrant.where(
          user_id: @user_id,
          scope_type: "Organization",
          scope_id: organization_id
        ).distinct.pluck(:permission).sort
      end
    end

    def for_account(account_id)
      cached(scope_type: "Account", scope_id: account_id) do
        account_ids = account_hierarchy_ids(account_id)
        CapabilityGrant
          .where(user_id: @user_id, scope_type: "Account", scope_id: account_ids)
          .where.not("permission LIKE ?", "msp.%")
          .distinct
          .pluck(:permission)
          .sort
      end
    end

    private

    def cached(scope_type:, scope_id:)
      return yield unless redis_enabled?

      key = cache_key(scope_type, scope_id)
      raw = @redis.get(key)
      return JSON.parse(raw) if raw.present?

      capabilities = yield
      @redis.set(key, capabilities.to_json, ex: TTL_SECONDS)
      capabilities
    end

    def account_hierarchy_ids(account_id)
      hierarchies = nil
      Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
        hierarchies = Account.with_parents_batch([account_id])
      end

      Array(hierarchies&.first).map { |account| account.id.to_s }
    end

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end

    def cache_key(scope_type, scope_id)
      "capabilities:#{@user_id}:#{scope_type}:#{scope_id}"
    end
  end
end
