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

    def get(_key)
      @null_pipeline_results << nil if @null_pipeline_results
      nil
    end

    def set(*, **)
      true
    end
  end

  def self.use_redis?
    ENV.fetch('GLOBAL_IAM_DEMO_USE_REDIS', 'true').match?(/\A(true|1|yes|on)\z/i)
  end
end

ORGANIZATION_CACHE = if IamDemo.use_redis?
  Redis.new(
    url: ENV.fetch('ORGANIZATION_CACHE_REDIS_URL') { 'redis://orgcache:6379/1' },
    timeout: 1.0
  )
else
  IamDemo::NullRedisCache.new
end
