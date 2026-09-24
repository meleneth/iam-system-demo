# frozen_string_literal: true

require "authorized_resource"
require "set"

class Account < AuthorizedResource::Base
  self.site = ENV.fetch("ACCOUNT_SERVICE_API_BASE_URL", "http://account-service:80")
  self.format = :json
  self.include_format_in_path = false
  self.primary_key = "id"
  self.collection_name = "accounts"

  schema do
    string "id"
    string "parent_account_id"
    string "name"
  end

  class << self
    def with_parents(account_id)
      authorized_read("with_parents") do
        raw = connection.get("/account_with_parents/#{account_id}.json", headers)
        ActiveSupport::JSON.decode(raw.body).map { |attributes| new(attributes) }
      end
    end

    def with_parents_batch(account_ids)
      Array(account_ids).each_slice(batch_size).flat_map do |ids|
        authorized_read("with_parents_batch") do
          raw = connection.post(
            "/accounts_with_parents",
            {account_ids: ids}.to_json,
            headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
          )
          ActiveSupport::JSON.decode(raw.body).map do |hierarchy|
            hierarchy.map { |attributes| new(attributes) }
          end
        end
      end
    end

    def with_parents_batch_ordered(account_ids)
      requested_ids = account_ids.map(&:to_s)
      unique_ids = requested_ids.uniq
      return [] if unique_ids.empty?

      requested = unique_ids.to_h { |id| [id, true] }
      duplicates = Set.new
      indexed = with_parents_batch(unique_ids).each_with_object({}) do |hierarchy, result|
        target_id = hierarchy.last&.id&.to_s
        next unless requested.key?(target_id)

        if result.key?(target_id)
          duplicates << target_id
          result.delete(target_id)
        elsif !duplicates.include?(target_id)
          result[target_id] = hierarchy
        end
      end

      requested_ids.map { |id| duplicates.include?(id) ? [] : indexed.fetch(id, []) }
    end

    def search(params)
      authorized_read("search") do
        raw = connection.post(
          "/accounts/search",
          params.to_json,
          headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
        )
        ActiveSupport::JSON.decode(raw.body).map { |attributes| new(attributes) }
      end
    end

    private

    def batch_size
      Integer(ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000"), 10).then do |size|
        raise ArgumentError, "IAM_DEMO_BATCH_SIZE must be between 1 and 10000" unless (1..10_000).cover?(size)
        size
      end
    rescue ArgumentError
      raise ArgumentError, "IAM_DEMO_BATCH_SIZE must be between 1 and 10000"
    end
  end
end
