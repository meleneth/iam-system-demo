# frozen_string_literal: true

require 'json'
require "awesome_print"

module Mel
  class MultiFetchCache
    def self.fetch_many(keys:, ttl:, tag: nil, cache:, key_proc:, tracking_key_proc: nil, &block)
      new(
        keys: keys,
        ttl: ttl,
        tag: tag,
        cache: cache,
        key_proc: key_proc,
        tracking_key_proc: tracking_key_proc
      ).fetch(&block)
    end

    def initialize(keys:, ttl:, tag:, cache:, key_proc:, tracking_key_proc:)
      @keys = keys
      @ttl = ttl
      @tag = tag
      @cache = cache
      @key_proc = key_proc
      @tracking_key_proc = tracking_key_proc
    end

    def fetch(&block)
      redis_keys = @keys.map { |k| @key_proc.call(k) }

      raw_values = {}
      @cache.pipelined do
        redis_keys.each do |redis_key|
          @cache.get(redis_key)
        end
      end.each_with_index do |result, i|
        raw_values[@keys[i]] = result
      end

      hits = raw_values.select { |_k, v| v }
      misses = raw_values.select { |_k, v| v.nil? }.keys

      new_values = {}
      if misses.any?
        new_values = if block.arity == 1
                      yield(misses)
                    else
                      yield(misses, self)
                    end
        unless new_values.is_a?(Hash)
          raise ArgumentError, "Block must return a hash of { logical_key => value }"
        end
      end

      # Write new values back into cache
      if new_values.any?
        @cache.pipelined do
          new_values.each do |logical_key, value|
            redis_key = @key_proc.call(logical_key)
            @cache.setex(redis_key, @ttl, value.to_json)

            if @tag && @tracking_key_proc
              tracking_key = @tracking_key_proc.call(logical_key)
              @cache.sadd(@tag, tracking_key)
            end
          end
        end
      end

      # Final result: combine hits + new_values
      final = {}
      @keys.each do |k|
        redis_key = @key_proc.call(k)
        val = raw_values[k]
        if val
          final[k] = JSON.parse(val)
        elsif new_values.key?(k)
          final[k] = new_values[k]
        else
          final[k] = nil
        end
      end

      final
    end
  end
end
