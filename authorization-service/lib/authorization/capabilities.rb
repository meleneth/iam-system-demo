# frozen_string_literal: true

require "json"

module Authorization
  class Capabilities
    TTL_SECONDS = 300

    def initialize(user_id:, redis: AUTHORIZATION_CACHE, account_context_client: AccountContextClient.new)
      @user_id = user_id
      @redis = redis
      @account_context_client = account_context_client
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
        hierarchy_ids = account_hierarchy_ids(account_id)
        direct_capabilities = CapabilityGrant
          .where(user_id: @user_id, scope_type: "Account", scope_id: hierarchy_ids)
          .where.not("permission LIKE ?", "msp.%")
          .distinct
          .pluck(:permission)

        (direct_capabilities + reflected_msp_account_capabilities(account_id, hierarchy_ids)).uniq.sort
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

    def reflected_msp_account_capabilities(account_id, hierarchy_ids)
      msp_organization_ids = CapabilityGrant
        .where(user_id: @user_id, scope_type: "Organization", permission: "msp.admin.users")
        .pluck(:scope_id)
        .map(&:to_s)
      return [] if msp_organization_ids.empty?

      account_grants = CapabilityGrant
        .where(user_id: @user_id, scope_type: "Account")
        .where.not(scope_id: hierarchy_ids)
        .where.not("permission LIKE ?", "msp.%")
        .pluck(:scope_id, :permission)

      permissions_by_msp_account_id = account_grants.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(scope_id, permission), memo|
        memo[scope_id.to_s] << permission
      end
      return [] if permissions_by_msp_account_id.empty?

      contexts = msp_organization_ids.flat_map do |msp_organization_id|
        permissions_by_msp_account_id.keys.map do |msp_account_id|
          {
            msp_organization_id: msp_organization_id,
            msp_account_id: msp_account_id,
            accounts: [
              {
                account_id: account_id.to_s,
                parent_account_ids: hierarchy_ids - [account_id.to_s]
              }
            ]
          }
        end
      end

      response = @account_context_client.account_contexts(contexts: contexts)
      Array(response.fetch("accounts")).flat_map do |account_context|
        permissions_by_msp_account_id[account_context.fetch("msp_account_id").to_s]
      end
    end

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end

    def cache_key(scope_type, scope_id)
      "capabilities:#{@user_id}:#{scope_type}:#{scope_id}"
    end
  end
end
