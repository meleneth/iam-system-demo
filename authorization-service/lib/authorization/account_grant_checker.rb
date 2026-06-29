# frozen_string_literal: true

module Authorization
  class AccountGrantChecker
    def initialize(user_id:, permission:, redis:)
      @user_id = user_id
      @permission = permission
      @redis = redis
      @user_grants_key = cached_user_grants(user_id, permission) if redis_enabled?
    end

		def authorized_for_all?(hierarchies)
			remaining = hierarchies.map.with_index { |h, i| [i, h.dup] }.to_h
			authorized = Set.new

			while remaining.any? { |_i, h| h.any? }
				next_ids_to_check = remaining.values.map(&:first).compact.map(&:id).uniq

				results = batch_check(next_ids_to_check)

				newly_authorized = []
				remaining.each do |index, hierarchy|
					if results[hierarchy.first&.id]
						authorized << index
						newly_authorized << index
					else
						# Remove just the head and continue
						remaining[index] = hierarchy[1..]
					end
				end

				newly_authorized.each { |i| remaining.delete(i) }
			end

			authorized.size == hierarchies.size
		end

    private

    def batch_check(account_ids)
      return {} if account_ids.empty?
      return batch_check_without_cache(account_ids) unless redis_enabled?

      values = @redis.pipelined do |pipe|
        account_ids.each { |id| pipe.sismember(@user_grants_key, id) }
      end

      account_ids.zip(values).to_h.transform_values(&:itself)
    end

    def batch_check_without_cache(account_ids)
      granted_ids = CapabilityGrant.where(
        user_id: @user_id,
        permission: @permission,
        scope_type: "Account",
        scope_id: account_ids
      ).pluck(:scope_id).map(&:to_s).to_set

      account_ids.to_h { |id| [id, granted_ids.include?(id.to_s)] }
    end

    def cached_user_grants(user_id, permission)
      key = "user_grants:#{user_id}:#{permission}"
      unless AUTHORIZATION_CACHE.exists?(key)
        scope_ids = CapabilityGrant.where(
          user_id: user_id,
          permission: permission,
          scope_type: "Account"
        ).pluck(:scope_id)
        AUTHORIZATION_CACHE.sadd(key, scope_ids) unless scope_ids.empty?
        AUTHORIZATION_CACHE.expire(key, 300)
      end
      key
    end

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end
  end
end
