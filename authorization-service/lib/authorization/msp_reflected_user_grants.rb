# frozen_string_literal: true

require "aws-sdk-sqs"
require "time"

module Authorization
  class MspReflectedUserGrants
    TTL_SECONDS = 300
    STALE_LOADING_SECONDS = 30
    QUEUE_URL = ENV.fetch("MSP_REFLECTED_GRANTS_QUEUE_URL", "http://eventstream:4566/000000000000/msp_reflected_grants")
    NATIVE_MSP_PERMISSIONS = ["account.users.create", "account.users.read"].freeze

    def initialize(redis: AUTHORIZATION_CACHE, organization_client: MspManagedAccountsClient.new)
      @redis = redis
      @organization_client = organization_client
    end

    def check(user_id:, msp_account_id:, account_ids:)
      account_ids = Array(account_ids).map(&:to_s)
      return check_without_cache(user_id: user_id, msp_account_id: msp_account_id, account_ids: account_ids) unless redis_enabled?

      current = status(user_id: user_id, msp_account_id: msp_account_id)

      unless current[:status] == "ready"
        if current[:status] == "missing" || stale_loading?(current)
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
      return unless redis_enabled?

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
    rescue => e
      mark_status(
        user_id,
        msp_account_id,
        status: "failed",
        loaded_count: 0,
        total_count: 0,
        error: "#{e.class}: #{e.message}",
        updated_at: Time.now.utc.iso8601
      )
      expire_keys(user_id, msp_account_id)
      raise
    end

    def load!(user_id:, msp_account_id:)
      return unless redis_enabled?

      Instrumentation.trace(
        "msp_reflected_user_grants.load",
        attributes: {
          "iam.user_id" => user_id,
          "iam.msp_account_id" => msp_account_id
        }
      ) do |span|
        load_with_trace!(span: span, user_id: user_id, msp_account_id: msp_account_id)
      end
    end

    def status(user_id:, msp_account_id:)
      raw = @redis.hgetall(status_key(user_id, msp_account_id))
      return missing_status unless raw.present?

      {
        status: raw.fetch("status", "missing"),
        loaded_count: raw.fetch("loaded_count", 0).to_i,
        total_count: raw.fetch("total_count", 0).to_i,
        started_at: raw["started_at"],
        updated_at: raw["updated_at"],
        error: raw["error"]
      }.compact
    end

    private

    def redis_enabled?
      !@redis.respond_to?(:redis_enabled?) || @redis.redis_enabled?
    end

    def check_without_cache(user_id:, msp_account_id:, account_ids:)
      authorized_account_ids = native_msp_user_management_grant?(user_id, msp_account_id) ? account_ids : []

      {
        status: "ready",
        loaded_count: account_ids.length,
        total_count: account_ids.length,
        loading: false,
        authorized_account_ids: authorized_account_ids
      }
    end

    def load_with_trace!(span:, user_id:, msp_account_id:)
      started_at_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loaded_count = 0
      page_count = 0
      total_count = 0
      now = Time.now.utc.iso8601
      @redis.del(set_key(user_id, msp_account_id))
      mark_status(user_id, msp_account_id, status: "loading", loaded_count: 0, total_count: 0, started_at: now, updated_at: now)

      first_page = load_organization_page(msp_account_id: msp_account_id)
      page_count += 1
      total_count = first_page.fetch("total_count").to_i
      span.set_attribute("iam.msp_reflected_grants.total_count", total_count)

      unless native_msp_user_management_grant?(user_id, msp_account_id)
        duration_ms = elapsed_ms(started_at_monotonic)
        mark_status(user_id, msp_account_id, status: "ready", loaded_count: 0, total_count: total_count, updated_at: Time.now.utc.iso8601)
        span.add_event(
          "msp_reflected_user_grants.ready_without_native_grant",
          attributes: {
            "iam.msp_reflected_grants.loaded_count" => 0,
            "iam.msp_reflected_grants.total_count" => total_count,
            "iam.msp_reflected_grants.page_count" => page_count,
            "iam.msp_reflected_grants.duration_ms" => duration_ms
          }
        )
        span.set_attribute("iam.msp_reflected_grants.loaded_count", 0)
        span.set_attribute("iam.msp_reflected_grants.page_count", page_count)
        span.set_attribute("iam.msp_reflected_grants.duration_ms", duration_ms)
        span.set_attribute("iam.msp_reflected_grants.status", "ready_without_native_grant")
        return
      end

      loaded_count = load_page(user_id, msp_account_id, first_page)
      mark_status(user_id, msp_account_id, status: "loading", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)
      span.add_event(
        "msp_reflected_user_grants.page_loaded",
        attributes: {
          "iam.msp_reflected_grants.page_count" => page_count,
          "iam.msp_reflected_grants.loaded_count" => loaded_count,
          "iam.msp_reflected_grants.total_count" => total_count
        }
      )

      continuance = first_page["continuance"]
      while continuance.present?
        page = load_organization_page(msp_account_id: msp_account_id, continuance: continuance)
        page_count += 1
        loaded_count += load_page(user_id, msp_account_id, page)
        mark_status(user_id, msp_account_id, status: "loading", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)
        span.add_event(
          "msp_reflected_user_grants.page_loaded",
          attributes: {
            "iam.msp_reflected_grants.page_count" => page_count,
            "iam.msp_reflected_grants.loaded_count" => loaded_count,
            "iam.msp_reflected_grants.total_count" => total_count
          }
        )
        continuance = page["continuance"]
      end

      duration_ms = elapsed_ms(started_at_monotonic)
      mark_status(user_id, msp_account_id, status: "ready", loaded_count: loaded_count, total_count: total_count, updated_at: Time.now.utc.iso8601)
      span.add_event(
        "msp_reflected_user_grants.ready",
        attributes: {
          "iam.msp_reflected_grants.loaded_count" => loaded_count,
          "iam.msp_reflected_grants.total_count" => total_count,
          "iam.msp_reflected_grants.page_count" => page_count,
          "iam.msp_reflected_grants.duration_ms" => duration_ms
        }
      )
      span.set_attribute("iam.msp_reflected_grants.loaded_count", loaded_count)
      span.set_attribute("iam.msp_reflected_grants.page_count", page_count)
      span.set_attribute("iam.msp_reflected_grants.duration_ms", duration_ms)
      span.set_attribute("iam.msp_reflected_grants.status", "ready")
    rescue => e
      duration_ms = elapsed_ms(started_at_monotonic)
      mark_status(user_id, msp_account_id, status: "failed", error: "#{e.class}: #{e.message}", updated_at: Time.now.utc.iso8601)
      span.record_exception(e)
      span.set_attribute("iam.msp_reflected_grants.status", "failed")
      span.set_attribute("iam.msp_reflected_grants.loaded_count", loaded_count)
      span.set_attribute("iam.msp_reflected_grants.total_count", total_count)
      span.set_attribute("iam.msp_reflected_grants.page_count", page_count)
      span.set_attribute("iam.msp_reflected_grants.duration_ms", duration_ms)
      raise
    ensure
      expire_keys(user_id, msp_account_id)
    end

    def stale_loading?(status)
      return false unless status[:status] == "loading"
      return false unless status[:loaded_count].zero? && status[:total_count].zero?

      updated_at = status[:updated_at] && Time.iso8601(status[:updated_at])
      return true unless updated_at

      Time.now.utc - updated_at > STALE_LOADING_SECONDS
    rescue ArgumentError
      true
    end

    def load_page(user_id, msp_account_id, page)
      account_ids = page.fetch("managed_account_ids").map(&:to_s)
      return 0 if account_ids.empty?

      @redis.sadd(set_key(user_id, msp_account_id), account_ids)
      expire_keys(user_id, msp_account_id)
      account_ids.length
    end

    def load_organization_page(msp_account_id:, continuance: nil)
      Instrumentation.trace(
        "msp_reflected_user_grants.organization_page",
        attributes: {
          "iam.msp_account_id" => msp_account_id,
          "iam.msp_reflected_grants.continuance_present" => continuance.present?
        }
      ) do |span|
        page = if continuance.present?
          @organization_client.page(msp_account_id: msp_account_id, continuance: continuance)
        else
          @organization_client.page(msp_account_id: msp_account_id)
        end
        span.set_attribute("iam.msp_reflected_grants.page_size", page.fetch("managed_account_ids").length)
        span.set_attribute("iam.msp_reflected_grants.total_count", page.fetch("total_count").to_i) if page.key?("total_count")
        span.set_attribute("iam.msp_reflected_grants.next_continuance_present", page["continuance"].present?)
        page
      end
    end

    def elapsed_ms(started_at_monotonic)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at_monotonic) * 1000).round(2)
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
