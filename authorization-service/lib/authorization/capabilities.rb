# frozen_string_literal: true

require "json"
require "set"

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

    def account_ids_with_permission(account_ids, permission)
      account_ids = Array(account_ids).map(&:to_s).uniq
      return Set.new if account_ids.empty?

      cached_results = Set.new
      unresolved_account_ids = []
      if redis_enabled?
        account_ids.each do |account_id|
          raw = @redis.get(account_permission_cache_key(permission, account_id))
          if raw.present?
            cached_results << account_id if raw == "true"
          else
            unresolved_account_ids << account_id
          end
        end
      else
        unresolved_account_ids = account_ids
      end

      authorized = cached_results.dup

      return authorized if unresolved_account_ids.empty?

      hierarchy_by_account_id = account_hierarchy_ids_for(unresolved_account_ids)
      permissions_by_account_id = unresolved_account_ids.each_with_object({}) do |account_id, memo|
        memo[account_id] = Set.new
      end

      direct_scope_ids = hierarchy_by_account_id.values.flatten.uniq
      CapabilityGrant
        .where(user_id: @user_id, scope_type: "Account", scope_id: direct_scope_ids, permission: permission)
        .where.not("permission LIKE ?", "msp.%")
        .pluck(:scope_id)
        .map(&:to_s)
        .then do |granted_scope_ids|
          granted_scope_id_set = granted_scope_ids.to_set
          hierarchy_by_account_id.each do |account_id, hierarchy_ids|
            permissions_by_account_id[account_id] << permission if hierarchy_ids.any? { |scope_id| granted_scope_id_set.include?(scope_id) }
          end
        end

      reflected_msp_account_ids_with_permission(
        unresolved_account_ids,
        hierarchy_by_account_id,
        permission
      ).each do |account_id|
        permissions_by_account_id[account_id] << permission
      end

      permissions_by_account_id.each do |account_id, permissions|
        permitted = permissions.include?(permission)
        authorized << account_id if permitted
        @redis.set(account_permission_cache_key(permission, account_id), permitted.to_s, ex: TTL_SECONDS) if redis_enabled?
      end

      authorized
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
      account_hierarchy_ids_for([account_id.to_s]).fetch(account_id.to_s, [])
    end

    def account_hierarchy_ids_for(account_ids)
      hierarchies = nil
      Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
        hierarchies = Account.with_parents_batch(account_ids)
      end

      account_ids.zip(Array(hierarchies)).to_h do |account_id, hierarchy|
        [account_id, Array(hierarchy).map { |account| account.id.to_s }]
      end
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

    def reflected_msp_account_ids_with_permission(account_ids, hierarchy_by_account_id, permission)
      msp_organization_ids = CapabilityGrant
        .where(user_id: @user_id, scope_type: "Organization", permission: "msp.admin.users")
        .pluck(:scope_id)
        .map(&:to_s)
      return Set.new if msp_organization_ids.empty?

      msp_account_ids = CapabilityGrant
        .where(user_id: @user_id, scope_type: "Account", permission: permission)
        .where.not("permission LIKE ?", "msp.%")
        .pluck(:scope_id)
        .map(&:to_s)
        .uniq
      return Set.new if msp_account_ids.empty?

      account_payloads = account_ids.map do |account_id|
        {
          account_id: account_id,
          parent_account_ids: hierarchy_by_account_id.fetch(account_id, []) - [account_id]
        }
      end

      contexts = msp_organization_ids.flat_map do |msp_organization_id|
        msp_account_ids.map do |msp_account_id|
          {
            msp_organization_id: msp_organization_id,
            msp_account_id: msp_account_id,
            accounts: account_payloads
          }
        end
      end

      response = @account_context_client.account_contexts(contexts: contexts)
      Array(response.fetch("accounts")).map { |account_context| account_context.fetch("account_id").to_s }.to_set
    end

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end

    def cache_key(scope_type, scope_id)
      "capabilities:#{@user_id}:#{scope_type}:#{scope_id}"
    end

    def account_permission_cache_key(permission, account_id)
      "can:#{@user_id}:Account:#{permission}:#{account_id}"
    end
  end
end
