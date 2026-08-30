# frozen_string_literal: true

require "json"
require "set"

module Authorization
  class Capabilities
    TTL_SECONDS = 300
    MAX_ACCOUNT_HIERARCHY_DEPTH = 100
    UUID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

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
      valid_account_ids = account_ids.select { |account_id| valid_account_id?(account_id) }
      return Set.new if valid_account_ids.empty?

      redis_enabled = redis_enabled?
      cached_values = read_account_permission_cache(valid_account_ids, permission, redis_enabled: redis_enabled)
      cached_results = valid_account_ids.each_with_object(Set.new) do |account_id, authorized|
        authorized << account_id if cached_values[account_id] == "true"
      end
      unresolved_account_ids = valid_account_ids.select { |account_id| cached_values[account_id].nil? }
      IamDemo::CacheMetrics.record(
        cache: "account_permission",
        outcome: "hit",
        count: valid_account_ids.size - unresolved_account_ids.size,
        redis_enabled: redis_enabled
      )
      IamDemo::CacheMetrics.record(
        cache: "account_permission",
        outcome: "miss",
        count: unresolved_account_ids.size,
        redis_enabled: redis_enabled
      )

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

      valid_account_ids = unresolved_account_ids.select { |account_id| hierarchy_by_account_id.fetch(account_id).any? }
      reflected_msp_account_ids_with_permission(
        valid_account_ids,
        hierarchy_by_account_id,
        permission
      ).each do |account_id|
        permissions_by_account_id[account_id] << permission
      end

      computed_results = permissions_by_account_id.to_h do |account_id, permissions|
        permitted = permissions.include?(permission)
        authorized << account_id if permitted
        [account_id, permitted]
      end
      write_account_permission_cache(computed_results, permission, redis_enabled: redis_enabled)

      authorized
    end

    private

    def valid_account_id?(account_id)
      UUID_PATTERN.match?(account_id)
    end

    def read_account_permission_cache(account_ids, permission, redis_enabled:)
      return {} unless redis_enabled

      values = @redis.pipelined do |pipeline|
        account_ids.each do |account_id|
          pipeline.get(account_permission_cache_key(permission, account_id))
        end
      end
      account_ids.zip(values).to_h
    rescue Redis::BaseError
      {}
    end

    def write_account_permission_cache(results, permission, redis_enabled:)
      return unless redis_enabled

      @redis.pipelined do |pipeline|
        results.each do |account_id, permitted|
          pipeline.set(
            account_permission_cache_key(permission, account_id),
            permitted.to_s,
            ex: TTL_SECONDS
          )
        end
      end
    rescue Redis::BaseError
      nil
    end

    def cached(scope_type:, scope_id:)
      unless redis_enabled?
        IamDemo::CacheMetrics.record(
          cache: "capabilities",
          outcome: "miss",
          count: 1,
          redis_enabled: false
        )
        return yield
      end

      key = cache_key(scope_type, scope_id)
      raw = @redis.get(key)
      if raw.present?
        IamDemo::CacheMetrics.record(
          cache: "capabilities",
          outcome: "hit",
          count: 1,
          redis_enabled: true
        )
        return JSON.parse(raw)
      end

      IamDemo::CacheMetrics.record(
        cache: "capabilities",
        outcome: "miss",
        count: 1,
        redis_enabled: true
      )

      capabilities = yield
      @redis.set(key, capabilities.to_json, ex: TTL_SECONDS)
      capabilities
    end

    def account_hierarchy_ids(account_id)
      return [] unless valid_account_id?(account_id.to_s)

      account_hierarchy_ids_for([account_id.to_s]).fetch(account_id.to_s, [])
    end

    def account_hierarchy_ids_for(account_ids)
      requested_ids = Array(account_ids).map(&:to_s).uniq
      hierarchies = nil
      Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
        hierarchies = Account.with_parents_batch(requested_ids)
      end

      requested_id_lookup = requested_ids.index_with(true)
      invalid_targets = Set.new
      indexed = Array(hierarchies).each_with_object({}) do |hierarchy, by_target|
        hierarchy = Array(hierarchy)
        target_id = hierarchy.last&.id&.to_s
        next unless requested_id_lookup.key?(target_id)

        if by_target.key?(target_id) || !valid_account_hierarchy?(hierarchy, target_id)
          invalid_targets << target_id
          by_target.delete(target_id)
          next
        end

        by_target[target_id] = hierarchy.map { |account| account.id.to_s }
      end

      requested_ids.to_h do |account_id|
        [account_id, invalid_targets.include?(account_id) ? [] : indexed.fetch(account_id, [])]
      end
    end

    def valid_account_hierarchy?(hierarchy, target_id)
      return false if hierarchy.empty? || hierarchy.size > MAX_ACCOUNT_HIERARCHY_DEPTH

      hierarchy_ids = hierarchy.map { |account| account.id.to_s }
      return false unless hierarchy_ids.last == target_id && hierarchy_ids.uniq.size == hierarchy_ids.size
      return false unless hierarchy.first.parent_account_id.blank?

      hierarchy.each_cons(2).all? do |ancestor, descendant|
        descendant.parent_account_id.to_s == ancestor.id.to_s
      end
    end

    def reflected_msp_account_capabilities(account_id, hierarchy_ids)
      return [] if hierarchy_ids.empty?

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
      return Set.new if account_ids.empty?

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
