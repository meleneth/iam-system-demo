# frozen_string_literal: true

require "json"
require "set"

module Authorization
  class Capabilities
    TTL_SECONDS = 300
    MAX_ACCOUNT_HIERARCHY_DEPTH = 100
    UUID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

    def initialize(user_id:, redis: AUTHORIZATION_CACHE, account_context_client: AccountContextClient.new, group_context_client: GroupContextClient.new)
      @user_id = user_id
      @group_context_client = group_context_client
      @redis = redis
      @account_context_client = account_context_client
    end

    def for_organization(organization_id)
      with_evaluation_context do
        organization_id = organization_id.to_s.downcase
        cached(scope_type: "Organization", scope_id: organization_id) do
          CapabilityGrant.where(
            group_id: group_ids,
            scope_type: "Organization",
            scope_id: organization_id
          ).distinct.pluck(:permission).sort
        end
      end
    end

    def for_account(account_id)
      with_evaluation_context do
        account_id = account_id.to_s.downcase
        cached(scope_type: "Account", scope_id: account_id) do
          scopes = account_scope_ids_for([account_id.to_s]).fetch(account_id.to_s)
          CapabilityGrant.where(group_id: group_ids, scope_type: "Account", scope_id: scopes)
            .distinct.pluck(:permission).sort
        end
      end
    end

    def for_group(group_id)
      with_evaluation_context do
        group_id = group_id.to_s.downcase
        cached(scope_type: "Group", scope_id: group_id) do
          group = @group_context_client.groups([group_id]).find { |row| row.fetch("id").to_s == group_id.to_s }
          next [] unless group

          direct = CapabilityGrant.where(group_id: group_ids, scope_type: "Group", scope_id: group_id)
            .distinct.pluck(:permission)
          (direct + for_account(group.fetch("account_id"))).uniq.sort
        end
      end
    end

    def account_ids_with_permission(account_ids, permission)
      with_evaluation_context do
        requested = Array(account_ids).map(&:to_s).uniq
        authorized = canonical_account_ids_with_permission(requested.map(&:downcase), permission)
        requested.select { |id| authorized.include?(id.downcase) }.to_set
      end
    end

    def group_ids_with_permission(requested_group_ids, permission)
      with_evaluation_context do
        requested = Array(requested_group_ids).map(&:to_s).uniq
        canonical_ids = requested.map(&:downcase).select { |id| valid_group_id?(id) }
        return Set.new if canonical_ids.empty?

        groups_by_id = @group_context_client.groups(canonical_ids).each_with_object({}) do |group, indexed|
          group_id = group.fetch("id").to_s.downcase
          next unless canonical_ids.include?(group_id)

          indexed[group_id] = group
        end
        direct = CapabilityGrant.where(
          group_id: group_ids, scope_type: "Group", scope_id: groups_by_id.keys, permission: permission
        ).pluck(:scope_id).map { |id| id.to_s.downcase }.to_set
        account_ids = groups_by_id.values.map { |group| group.fetch("account_id").to_s }.uniq
        permitted_accounts = canonical_account_ids_with_permission(account_ids.map(&:downcase), permission)

        requested.select do |requested_id|
          group = groups_by_id[requested_id.downcase]
          group && (direct.include?(requested_id.downcase) || permitted_accounts.include?(group.fetch("account_id").to_s.downcase))
        end.to_set
      end
    end

    private

    def with_evaluation_context(&block)
      AuthorizationContext.as_iam(originating_user_id: @user_id, &block)
    end

    def canonical_account_ids_with_permission(account_ids, permission)
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

      hierarchy_by_account_id = account_scope_ids_for(unresolved_account_ids)
      permissions_by_account_id = unresolved_account_ids.each_with_object({}) do |account_id, memo|
        memo[account_id] = Set.new
      end

      direct_scope_ids = hierarchy_by_account_id.values.flatten.uniq
      CapabilityGrant
        .where(group_id: group_ids, scope_type: "Account", scope_id: direct_scope_ids, permission: permission)
        .pluck(:scope_id)
        .map(&:to_s)
        .then do |granted_scope_ids|
          granted_scope_id_set = granted_scope_ids.to_set
          hierarchy_by_account_id.each do |account_id, hierarchy_ids|
            permissions_by_account_id[account_id] << permission if hierarchy_ids.any? { |scope_id| granted_scope_id_set.include?(scope_id) }
          end
        end

      computed_results = permissions_by_account_id.to_h do |account_id, permissions|
        permitted = permissions.include?(permission)
        authorized << account_id if permitted
        [account_id, permitted]
      end
      write_account_permission_cache(computed_results, permission, redis_enabled: redis_enabled)

      authorized
    end

    def group_ids
      @group_ids ||= @group_context_client.group_ids_for(@user_id)
    end

    def valid_account_id?(account_id)
      UUID_PATTERN.match?(account_id)
    end

    alias_method :valid_group_id?, :valid_account_id?

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
      raw = begin
        @redis.get(key)
      rescue Redis::BaseError
        nil
      end
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
      begin
        @redis.set(key, capabilities.to_json, ex: TTL_SECONDS)
      rescue Redis::BaseError
        # A failed cache write does not change the authoritative result.
      end
      capabilities
    end

    def account_hierarchy_ids_for(account_ids)
      requested_ids = Array(account_ids).map(&:to_s).uniq
      hierarchies = nil
      AuthorizationContext.as_iam(originating_user_id: @user_id) do
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

    # Physical parents stay inside their organization. Organization-service adds
    # provider edges to this authorization-only graph; client responses never see it.
    def account_scope_ids_for(account_ids)
      requested = Array(account_ids).map(&:to_s).uniq
      hierarchies = {}
      providers = {}
      frontier = requested.select { |id| valid_account_id?(id) }
      MAX_ACCOUNT_HIERARCHY_DEPTH.times do
        break if frontier.empty?
        batch = account_hierarchy_ids_for(frontier)
        hierarchies.merge!(batch)
        valid = frontier.select { |id| batch.fetch(id).any? }
        unless valid.empty?
          rows = @account_context_client.providers_for(account_ids: valid).fetch("accounts")
          rows.each do |row|
            target = row.fetch("account_id").to_s
            provider = row.fetch("msp_account_id").to_s
            raise "Invalid provider context" unless valid.include?(target) && valid_account_id?(provider) && !providers.key?(target)
            providers[target] = provider
          end
        end
        frontier = valid.filter_map { |id| providers[id] }.uniq.reject { |id| hierarchies.key?(id) }
      end

      requested.to_h do |target|
        scopes = []
        visited = Set.new
        current = target
        while current
          unless visited.add?(current)
            scopes = []
            break
          end
          # Bound the path itself, including nodes already loaded by another target.
          raise "Provider hierarchy exceeds maximum depth" if visited.size > MAX_ACCOUNT_HIERARCHY_DEPTH
          chain = hierarchies.fetch(current, [])
          if chain.empty?
            scopes = []
            break
          end
          scopes.concat(chain)
          current = providers[current]
        end
        [target, scopes.uniq]
      end
    end

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end

    def cache_key(scope_type, scope_id)
      "group-grants-v2:capabilities:#{@user_id}:#{scope_type}:#{scope_id}"
    end

    def account_permission_cache_key(permission, account_id)
      "group-grants-v2:can:#{@user_id}:Account:#{permission}:#{account_id}"
    end
  end
end
