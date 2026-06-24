# frozen_string_literal: true

require "aws-sdk-sqs"
require "time"

module Authorization
  class MspReflectedUserGrants
    TTL_SECONDS = 3_600
    PAGE_SIZE = 1_000
    QUEUE_URL = ENV.fetch("MSP_REFLECTED_GRANTS_QUEUE_URL", "http://eventstream:4566/000000000000/msp_reflected_grants")
    NATIVE_MSP_PERMISSIONS = ["account.users.create", "account.users.read"].freeze

    def initialize(redis: AUTHORIZATION_CACHE, organization_client: MspManagedAccountsClient.new)
      @redis = redis
      @organization_client = organization_client
    end

    def check(user_id:, msp_account_id:, account_ids:)
      account_ids = Array(account_ids).map(&:to_s)
      current = status(user_id: user_id, msp_account_id: msp_account_id)

      unless current[:status] == "ready"
        if current[:status] == "missing"
          request_load(user_id: user_id, msp_account_id: msp_account_id)
          current = status(user_id: user_id, msp_account_id: msp_account_id)
        end
        return current.merge(loading: true, authorized_account_ids: [])
      end

      values = @redis.pipelined do |pipe|
        account_ids.each { |account_id| pipe.sismember(set_key(user_id, msp_account_id), account_id) }
      end

      authorized_account_ids = account_ids.zip(values).filter_map { |account_id, allowed| account_id if allowed }
      current.merge(loading: false, authorized_account_ids: authorized_account_ids)
    end

    def request_load(user_id:, msp_account_id:)
      now = Time.now.utc.iso8601
      @redis.mapped_hmset(
        status_key(user_id, msp_account_id),
        status: "loading",
        loaded_count: 0,
        total_count: 0,
        started_at: now,
        updated_at: now
      )
      expire_keys(user_id, msp_account_id)

      sqs.send_message(
        queue_url: QUEUE_URL,
        message_body: JSON.dump(
          type: "msp_reflected_user_grants.load",
          user_id: user_id,
          msp_account_id: msp_account_id
        )
      )
    end

    def load!(user_id:, msp_account_id:)
      now = Time.now.utc.iso8601
      @redis.del(set_key(user_id, msp_account_id))
      mark_status(user_id, msp_account_id, status: "loading", loaded_count: 0, total_count: 0, started_at: now, updated_at: now)

      first_page = @organization_client.page(msp_account_id: msp_account_id, offset: 0, limit: PAGE_SIZE)
      total_count = first_page.fetch("total_count").to_i

      unless native_msp_user_management_grant?(user_id, msp_account_id)
        mark_status(user_id, msp_account_id, status: "ready", loaded_count: 0, total_count: total_count, updated_at: Time.now.utc.iso8601)
        return
      end

      loaded_count = load_page(user_id, msp_account_id, first_page)
      mark_status(user_id, msp_account_id, status: "loading", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)

      while loaded_count < total_count
        page = @organization_client.page(msp_account_id: msp_account_id, offset: loaded_count, limit: PAGE_SIZE)
        loaded_count += load_page(user_id, msp_account_id, page)
        mark_status(user_id, msp_account_id, status: "loading", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)
      end

      mark_status(user_id, msp_account_id, status: "ready", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)
    rescue => e
      mark_status(user_id, msp_account_id, status: "failed", error: "#{e.class}: #{e.message}", updated_at: Time.now.utc.iso8601)
      raise
    ensure
      expire_keys(user_id, msp_account_id)
    end

    def status(user_id:, msp_account_id:)
      raw = @redis.hgetall(status_key(user_id, msp_account_id))
      return missing_status unless raw.present?

      {
        status: raw.fetch("status", "missing"),
        loaded_count: raw.fetch("loaded_count", 0).to_i,
        total_count: raw.fetch("total_count", 0).to_i,
        error: raw["error"]
      }.compact
    end

    private

    def load_page(user_id, msp_account_id, page)
      account_ids = page.fetch("managed_account_ids").map(&:to_s)
      return 0 if account_ids.empty?

      @redis.sadd(set_key(user_id, msp_account_id), account_ids)
      expire_keys(user_id, msp_account_id)
      account_ids.length
    end

    def native_msp_user_management_grant?(user_id, msp_account_id)
      CapabilityGrant.where(
        user_id: user_id,
        scope_type: "Account",
        scope_id: msp_account_id,
        permission: NATIVE_MSP_PERMISSIONS
      ).exists?
    end

    def mark_status(user_id, msp_account_id, attributes)
      @redis.mapped_hmset(status_key(user_id, msp_account_id), attributes.compact)
    end

    def expire_keys(user_id, msp_account_id)
      @redis.expire(status_key(user_id, msp_account_id), TTL_SECONDS)
      @redis.expire(set_key(user_id, msp_account_id), TTL_SECONDS)
    end

    def missing_status
      { status: "missing", loaded_count: 0, total_count: 0 }
    end

    def status_key(user_id, msp_account_id)
      "msp_reflected_user_grants:#{user_id}:#{msp_account_id}:status"
    end

    def set_key(user_id, msp_account_id)
      "msp_reflected_user_grants:#{user_id}:#{msp_account_id}:manage_users"
    end

    def sqs
      @sqs ||= Aws::SQS::Client.new(
        region: "us-east-1",
        endpoint: "http://eventstream:4566",
        access_key_id: "fake",
        secret_access_key: "fake"
      )
    end
  end
end
