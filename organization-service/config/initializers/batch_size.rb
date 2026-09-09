# frozen_string_literal: true

module IamDemo
  class InvalidBatchSize < StandardError; end

  def self.batch_size
    raw = ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000")
    unless /\A[0-9]+\z/.match?(raw) && (1..10_000).cover?(raw.to_i)
      raise InvalidBatchSize, "IAM_DEMO_BATCH_SIZE must be an integer between 1 and 10000, got #{raw.inspect}"
    end
    raw.to_i
  end
end
