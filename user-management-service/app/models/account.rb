# frozen_string_literal: true

require "set"

# app/models/account.rb
class Account < AuthorizedResource::Base
  self.site = ENV.fetch("ACCOUNT_SERVICE_API_BASE_URL", "http://account-service:80")
  self.format = :json

  self.include_format_in_path = false

  schema do
    string 'id'
    string 'parent_account_id'
    string 'name'
  end

  # Optional: if the resource uses UUIDs instead of integers
  self.primary_key = "id"

  # Optional: if user-service uses a different collection path
  self.collection_name = "accounts"

  def self.with_parents(account_id)
    authorized_read("with_parents") do
      path = "/account_with_parents/#{account_id}.json"
      raw = connection.get(path, headers)
      ActiveSupport::JSON.decode(raw.body).map { |attrs| new(attrs) }
    end
  end

  def self.with_parents_batch(account_ids)
    Array(account_ids).each_slice(IamDemo.batch_size).flat_map do |ids|
      authorized_read("with_parents_batch") do
        raw = connection.post(
          "/accounts_with_parents",
          { account_ids: ids }.to_json,
          headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
        )
        ActiveSupport::JSON.decode(raw.body).map do |account_group|
          account_group.map { |attrs| new(attrs) }
        end
      end
    end
  end

  def self.with_parents_batch_ordered(account_ids)
    requested_ids = account_ids.map(&:to_s)
    unique_ids = requested_ids.uniq
    return [] if unique_ids.empty?
    requested_id_lookup = unique_ids.index_with(true)

    duplicate_ids = Set.new
    hierarchies_by_id = with_parents_batch(unique_ids).each_with_object({}) do |hierarchy, indexed|
      target_id = hierarchy.last&.id&.to_s
      next unless requested_id_lookup.key?(target_id)

      if indexed.key?(target_id)
        duplicate_ids << target_id
        indexed.delete(target_id)
      elsif !duplicate_ids.include?(target_id)
        indexed[target_id] = hierarchy
      end
    end

    requested_ids.map do |account_id|
      duplicate_ids.include?(account_id) ? [] : hierarchies_by_id.fetch(account_id, [])
    end
  end

  def self.search(params)
    authorized_read("search") do
      raw = connection.post(
        "/accounts/search",
        params.to_json,
        headers.merge("Accept" => "application/json", "Content-Type" => "application/json")
      )
      ActiveSupport::JSON.decode(raw.body).map { |attrs| new(attrs) }
    end
  end


  # Optional: handle nested resources, errors, etc.
end
