# frozen_string_literal: true
# app/models/account.rb
require "async/http/internet"

class Account < ActiveResource::Base
  extend FiberHeaderHelpers
  INTERNET = Async::HTTP::Internet.new

  self.site  = ENV.fetch("ACCOUNT_SERVICE_API_BASE_URL") # e.g., http://account-service:80/
  self.format = :json
  self.include_format_in_path = false
  self.primary_key = "id"
  self.collection_name = "accounts"

  schema do
    string "id"
    string "parent_account_id"
    string "name"
  end

  # ------- existing sync helpers (unchanged) -------
  def self.with_parents(account_id)
    path = "/account_with_parents/#{account_id}.json"
    raw  = connection.get(path, headers)  # <- blocking
    ActiveSupport::JSON.decode(raw.body).map { |attrs| new(attrs) }
  end

  def self.with_parents_batch(account_ids)
    qs   = URI.encode_www_form(account_ids.map { |id| ["account_ids[]", id] })
    path = "/accounts_with_parents.json?#{qs}"
    raw  = connection.get(path, headers)  # <- blocking
    ActiveSupport::JSON.decode(raw.body).map { |group| group.map { |attrs| new(attrs) } }
  end

  # ------- ASYNC versions (non-blocking) -------

  def self.with_parents_async(account_id)
    path = "/account_with_parents/#{account_id}.json"
    url  = URI.join(site.to_s, path).to_s

    resp = INTERNET.get(url, current_headers)
    # async-http: resp.respond_to?(:read)
    data = ActiveSupport::JSON.decode(resp.read)

    Array(data).map { |attrs| new(attrs) }
  end

  def self.with_parents_batch_async(account_ids)
    qs   = URI.encode_www_form(account_ids.map { |id| ["account_ids[]", id] })
    url  = URI.join(site.to_s, "/accounts_with_parents.json?#{qs}").to_s

    resp = INTERNET.get(url, current_headers)
    data = ActiveSupport::JSON.decode(resp.read)

    Array(data).map { |group| Array(group).map { |attrs| new(attrs) } }
  end


  # Build a proper collection URL using ActiveResource’s own path logic.
  def self._collection_url(params = {})
    # ActiveResource::Base#collection_path respects include_format_in_path
    path = collection_path(params) # e.g., "/accounts.json?foo=bar" or "/accounts?foo=bar"
    URI.join(site.to_s, path).to_s
  end

  # Async WHERE: returns an array of Account records.
  #
  # Examples:
  #   Account.where_async(name: "Acme")
  #   Account.where_async(account_ids: ["a", "b"])          # → ?account_ids[]=a&account_ids[]=b
  #   Account.where_async({ q: "foo", page: 2, per: 50 })
  def self.where_async(params = {})
    url  = _collection_url(params)
    resp = INTERNET.get(url, current_headers)

    case resp.status
    when 200
      data = ActiveSupport::JSON.decode(resp.read)
      Array(data).map { |attrs| new(attrs) }
    when 404
      [] # ARes.find(:all) would return [], keep parity
    else
      body = resp.read
      raise ActiveResource::ClientError.new(resp), "HTTP #{resp.status} calling #{url} :: #{body}"
    end
  end

  # Async FIND by id (handy parity helper).
  def self.find_async(id, params = {})
    # ActiveResource's element_path builds /accounts/:id(.json)?...
    path = element_path(id, params)
    url  = URI.join(site.to_s, path).to_s
    resp = INTERNET.get(url, current_headers)

    case resp.status
    when 200
      new(ActiveSupport::JSON.decode(resp.read))
    when 404
      raise ActiveResource::ResourceNotFound.new(resp)
    else
      body = resp.read
      raise ActiveResource::ClientError.new(resp), "HTTP #{resp.status} calling #{url} :: #{body}"
    end
  end
end
