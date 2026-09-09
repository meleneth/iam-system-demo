# frozen_string_literal: true

require "json"
require "cgi"

module BenchmarkResponse
  def self.inspect_response(path, http_code:, curl_exit:, partition: false, graphql: false)
    result = { "outcome" => "ok" }
    if curl_exit != 0
      return result.merge("outcome" => curl_exit == 28 ? "timeout" : "transport_error", "curl_exit" => curl_exit)
    end
    return result.merge("outcome" => "http_error") unless http_code == 200

    raw = File.read(path)
    if partition
      script = raw.match(/<script\b[^>]*type=["']application\/json["'][^>]*>(.*?)<\/script>/m)
      raise "Missing partition payload" unless script
      payload = JSON.parse(script[1])
      accounts = payload.fetch("accounts")
      users = payload.fetch("users")
      raise "Incomplete account partition" unless accounts.size == payload.fetch("partition_account_count")
      raise "Duplicate accounts" unless accounts.map { |row| row.fetch("id") }.uniq.size == accounts.size
      result.merge!("accounts" => accounts.size, "users" => users.size,
        "groups" => users.flat_map { |row| row.fetch("groups") }.map { |row| row.fetch("id") }.uniq.size,
        "memberships" => users.sum { |row| row.fetch("groups").size },
        "total_accounts" => payload.fetch("total_account_count"),
        "retrieval_mode" => payload.fetch("retrieval_mode"), "batch_size" => payload.fetch("batch_size"))
      src = raw.match(/<turbo-frame\b[^>]*\bsrc=["']([^"']+)["']/)
      result["next_path"] = CGI.unescapeHTML(src[1]) if src
    elsif graphql
      payload = JSON.parse(raw)
      if Array(payload["errors"]).any?
        return result.merge("outcome" => "graphql_errors", "errors" => payload["errors"])
      end
      raise "Missing GraphQL data" unless payload["data"].is_a?(Hash) && !payload["data"].empty?
      raise "Null GraphQL result" if payload["data"].values.any?(&:nil?)
    end
    result
  rescue JSON::ParserError, KeyError, RuntimeError => error
    result.merge("outcome" => "invalid_response", "error" => error.message)
  end
end

if $PROGRAM_NAME == __FILE__
  path, http_code, curl_exit, kind = ARGV
  result = BenchmarkResponse.inspect_response(path, http_code: http_code.to_i, curl_exit: curl_exit.to_i,
    partition: kind == "partition", graphql: kind == "graphql")
  File.write("#{path}.result.json", JSON.pretty_generate(result) + "\n")
  puts "outcome=#{result.fetch('outcome')} curl_exit=#{curl_exit}"
end
