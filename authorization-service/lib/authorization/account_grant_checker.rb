# frozen_string_literal: true

module Authorization
  class AccountGrantChecker
    def initialize(user_id:, permission:, redis:)
      @user_id = user_id
      @permission = permission
      @redis = redis
      @user_grants_key = cached_user_grants(user_id, permission)
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
      values = @redis.pipelined do |pipe|
        account_ids.each { |id| pipe.sismember(@user_grants_key, id) }
      end

      account_ids.zip(values).to_h.transform_values(&:itself)
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
  end
end
