# frozen_string_literal: true

require 'redis'

AUTHORIZATION_CACHE = Redis.new(
  url: ENV.fetch('ACCOUNT_CACHE_REDIS_URL') { 'redis://authcache:6379/1' },
  timeout: 1.0
)
