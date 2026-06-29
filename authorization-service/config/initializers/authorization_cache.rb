# frozen_string_literal: true

require 'redis'

module IamDemo
  class NullRedisCache
    def redis_enabled?
      false
    end

    def pipelined
      @null_pipeline_results = []
      yield self
      @null_pipeline_results
    ensure
      @null_pipeline_results = nil
    end

    def exists?(_key)
      false
    end

    def sadd(*, **)
      true
    end

    def expire(*, **)
      true
    end

    def sismember(*, **)
      @null_pipeline_results << false if @null_pipeline_results
      false
    end

    def mapped_hmset(*, **)
      true
    end

    def hgetall(_key)
      {}
    end

    def del(*, **)
      true
    end
  end

  def self.use_redis?
    ENV.fetch('GLOBAL_IAM_DEMO_USE_REDIS', 'true').match?(/\A(true|1|yes|on)\z/i)
  end
end

AUTHORIZATION_CACHE = if IamDemo.use_redis?
  Redis.new(
    url: ENV.fetch('AUTHORIZATION_CACHE_REDIS_URL') { 'redis://authcache:6379/1' },
    timeout: 1.0
  )
else
  IamDemo::NullRedisCache.new
end
