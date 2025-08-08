# frozen_string_literal: true

require 'redis'

ORGANIZATION_CACHE = Redis.new(
  url: ENV.fetch('ORGANIZATION_CACHE_REDIS_URL') { 'redis://orgcache:6379/1' },
  timeout: 1.0
)
