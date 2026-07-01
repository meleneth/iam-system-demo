# frozen_string_literal: true

require "thread"

module IamDemo
  module CacheMetrics
    @mutex = Mutex.new
    @counts = Hash.new(0)

    class << self
      def record(cache:, outcome:, count:, redis_enabled:)
        return if count.to_i <= 0

        labels = {
          service: "organization-service",
          cache: cache.to_s,
          outcome: outcome.to_s,
          redis: redis_enabled ? "true" : "false"
        }

        @mutex.synchronize { @counts[labels] += count.to_i }
      end

      def prometheus_text
        rows = [
          "# HELP iam_demo_cache_requests_total Cache read results by service, cache, outcome, and Redis mode.",
          "# TYPE iam_demo_cache_requests_total counter"
        ]

        @mutex.synchronize do
          @counts.each do |labels, value|
            rows << "iam_demo_cache_requests_total{#{format_labels(labels)}} #{value}"
          end
        end

        "#{rows.join("\n")}\n"
      end

      private

      def format_labels(labels)
        labels.map { |key, value| "#{key}=\"#{escape_label(value)}\"" }.join(",")
      end

      def escape_label(value)
        value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"').gsub("\n", "\\n")
      end
    end
  end
end
