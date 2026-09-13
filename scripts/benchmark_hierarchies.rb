# frozen_string_literal: true

require "json"
require "csv"
require "digest"
require "fileutils"
require "net/http"
require "securerandom"
require "time"
require_relative "archive_trace"

class HierarchyComparison
  class Failure < StandardError
    attr_reader :outcome
    def initialize(outcome, message)
      @outcome = outcome
      super(message)
    end
  end

  def initialize(base_url:, actor:, batch_size:, timeout:, request: nil)
    raise ArgumentError, "A real actor is required" if actor.to_s.empty? || actor.start_with?("IAM_SYSTEM")
    raise ArgumentError, "Invalid batch size" unless (1..10_000).cover?(batch_size)
    @base_url, @actor, @batch_size, @timeout = base_url.delete_suffix("/"), actor, batch_size, timeout
    @request = request || method(:http_request)
  end

  def measure(mode:, target_ids:, expected:, directory:)
    FileUtils.mkdir_p(directory)
    @directory, @requests = directory, []
    @trace_id, @parent_id = SecureRandom.hex(16), SecureRandom.hex(8)
    started = monotonic
    @deadline = started + @timeout
    result = { mode: mode, actor: @actor, target_ids: target_ids, batch_size: @batch_size,
      trace_id: @trace_id, initiating_span_id: @parent_id, outcome: "ok" }
    begin
      actual = retrieve(mode, target_ids)
      normalized = actual.map { |chain| chain.map { |row| row.slice("id", "parent_account_id") } }
      wanted = target_ids.map { |id| expected.fetch(id) }
      raise Failure.new("inequivalent_result", "Hierarchy identities or parent links differ from fixture") unless normalized == wanted
      result[:returned_accounts] = normalized.sum(&:length)
      result[:result_sha256] = Digest::SHA256.hexdigest(JSON.generate(normalized))
      File.write(File.join(directory, "hierarchies.json"), JSON.pretty_generate(actual))
    rescue Failure => error
      result.merge!(outcome: error.outcome, error: error.message)
    rescue Timeout::Error => error
      result.merge!(outcome: "timeout", error: error.message)
    rescue StandardError => error
      result.merge!(outcome: "error", error: "#{error.class}: #{error.message}")
    ensure
      result.merge!(duration_seconds: monotonic - started, request_count: @requests.size,
        response_bytes: @requests.sum { |request| request.fetch(:bytes, 0) }, timeout_seconds: @timeout)
      File.write(File.join(directory, "requests.json"), JSON.pretty_generate(@requests))
    end
    result
  end

  def self.expected_chain(fixture, target_id)
    by_id = fixture.fetch("accounts").to_h { |account| [account.fetch("id"), account] }
    chain = []
    id = target_id
    while id
      raise "Cyclic fixture" if chain.any? { |account| account.fetch("id") == id }
      account = by_id.fetch(id).slice("id", "parent_account_id")
      chain.unshift(account)
      id = account.fetch("parent_account_id")
    end
    chain
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def retrieve(mode, ids)
    case mode
    when "walk"
      ids.map do |id|
        chain, seen = [], {}
        while id
          raise Failure.new("invalid_hierarchy", "Cycle or depth limit") if seen[id] || seen.size >= 100
          seen[id] = true
          account = call("GET", "/accounts/#{id}")
          raise Failure.new("invalid_hierarchy", "Wrong account returned") unless account.fetch("id") == id
          chain.unshift(account)
          id = account.fetch("parent_account_id")
        end
        chain
      end
    when "cte", "individual"
      ids.map { |id| call("GET", "/account_with_parents/#{id}") }
    when "batch"
      ids.each_slice(@batch_size).flat_map do |slice|
        chains = call("POST", "/accounts_with_parents", { account_ids: slice })
        by_target = chains.to_h { |chain| [chain.last&.fetch("id"), chain] }
        raise Failure.new("invalid_hierarchy", "Duplicate or missing targets") unless chains.size == slice.size && by_target.keys.sort == slice.sort
        slice.map { |id| by_target.fetch(id) }
      end
    else
      raise ArgumentError, "Unknown mode #{mode}"
    end
  end

  def call(method, path, body = nil)
    remaining = @deadline - monotonic
    raise Timeout::Error, "Whole-sample deadline exceeded" unless remaining.positive?
    record = { method: method, path: path, actor: @actor }
    @requests << record
    started = monotonic
    headers = { "pad-user-id" => @actor, "traceparent" => "00-#{@trace_id}-#{@parent_id}-01", "Accept" => "application/json" }
    status, raw = @request.call(method, path, body, headers, remaining)
    record.merge!(http_status: status, bytes: raw.bytesize)
    File.write(File.join(@directory, "response-#{@requests.size}.json"), raw)
    raise Failure.new("http_error", "#{method} #{path}: HTTP #{status}") unless status == 200
    JSON.parse(raw)
  ensure
    record[:duration_seconds] = monotonic - started if record && started
  end

  def http_request(method, path, body, headers, remaining)
    uri = URI(@base_url + path)
    request = method == "POST" ? Net::HTTP::Post.new(uri, headers) : Net::HTTP::Get.new(uri, headers)
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: [remaining, 5].min, read_timeout: remaining, write_timeout: remaining) { |http| http.request(request) }
    [response.code.to_i, response.body]
  end
end

require_relative "benchmark_environment"
require_relative "authorization_correctness_gate"

if $PROGRAM_NAME == __FILE__
  ENV.update(BenchmarkEnvironment.values)
  manifest_path = ENV.fetch("MANIFEST")
  manifest = JSON.parse(File.read(manifest_path))
  out = ENV.fetch("OUT_DIR", "reports/raw/hierarchies-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
  raise "Refusing to overwrite benchmark evidence: #{out}" if File.exist?(File.join(out, "timings.csv"))
  FileUtils.mkdir_p(out)
  AuthorizationCorrectnessGate.new.run(output: File.join(out, "authorization-correctness.json"))
  FileUtils.cp(manifest_path, File.join(out, "fixture_manifest.json"))
  redis = ENV.fetch("GLOBAL_IAM_DEMO_USE_REDIS", "false")
  raise "GLOBAL_IAM_DEMO_USE_REDIS must be true or false" unless %w[true false].include?(redis)
  batch_size = Integer(ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000"), 10)
  runs = Integer(ENV.fetch("RUNS", "3"), 10)
  experiment = ENV.fetch("EXPERIMENT", "all")
  raise "EXPERIMENT must be all, cte, or batch" unless %w[all cte batch].include?(experiment)
  cases = []
  deep = manifest.fetch("fixtures").find { |fixture| fixture.fetch("name") == "deep_chain" }
  if %w[all cte].include?(experiment)
    ENV.fetch("DEPTHS", "1,5,10,25").split(",").map { |n| Integer(n, 10) }.each do |depth|
      target = deep.fetch("accounts").find { |account| HierarchyComparison.expected_chain(deep, account.fetch("id")).length == depth }
      raise "No depth #{depth} in fixture" unless target
      cases << ["depth-#{depth}", deep, [target.fetch("id")], %w[walk cte]]
    end
  end
  if %w[all batch].include?(experiment)
    %w[deep_chain wide_org].each do |name|
      fixture = manifest.fetch("fixtures").find { |item| item.fetch("name") == name }
      ids = fixture.fetch("accounts").map { |account| account.fetch("id") }
      [1, 8, ids.size].uniq.each { |size| cases << ["#{name}-targets-#{size}", fixture, ids.last(size), %w[individual batch]] }
    end
  end
  metadata = { revision: `git rev-parse HEAD`.strip, manifest_sha256: Digest::SHA256.file(manifest_path).hexdigest,
    redis_enabled: redis == "true", authorization_mode: ENV.fetch("AUTHORIZATION_CHECK_MODE", "can"),
    batch_size: batch_size, runs: runs, experiment: experiment, started_at: Time.now.utc.iso8601,
    note: "Actor-authorized end-to-end hierarchy requests; includes authorization and organization lookup work, not isolated SQL timing." }
  File.write(File.join(out, "metadata.json"), JSON.pretty_generate(metadata))
  failed = false
  phases = redis == "true" ? %w[cold warm] : ["redis_disabled"]
  CSV.open(File.join(out, "timings.csv"), "w") do |csv|
    csv << %w[case phase run mode outcome duration_seconds request_count response_bytes trace_id sample_directory]
    cases.each do |label, fixture, ids, modes|
      actor = fixture.fetch("targets").fetch("top_level_admin_user_id")
      expected = ids.to_h { |id| [id, HierarchyComparison.expected_chain(fixture, id)] }
      runner = HierarchyComparison.new(base_url: ENV.fetch("ACCOUNT_SERVICE_BASE_URL"),
        actor: actor, batch_size: batch_size, timeout: Float(ENV.fetch("REQUEST_TIMEOUT_SECONDS", "120")))
      phases.each do |phase|
        runs.times do |run|
          # Alternate the first mode to reduce ordering bias.
          (run.even? ? modes : modes.reverse).each do |mode|
            directory = File.join(out, "#{label}-#{phase}-#{run + 1}-#{mode}")
            if phase == "cold"
              %w[accountcache authcache orgcache groupcache].each do |service|
                raise "Cache flush failed" unless system(ENV.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "redis-cli", "-n", ENV.fetch("REDIS_CACHE_DB", "1"), "FLUSHDB", out: File::NULL)
              end
            elsif phase == "warm"
              prime = runner.measure(mode: mode, target_ids: ids, expected: expected, directory: directory + "-prime")
              File.write(directory + "-prime/result.json", JSON.pretty_generate(prime))
              failed ||= prime.fetch(:outcome) != "ok"
            end
            result = runner.measure(mode: mode, target_ids: ids, expected: expected, directory: directory)
            if ENV.fetch("ARCHIVE_TRACES", "1") == "1"
              archive = TraceArchive.new(base_url: ENV.fetch("JAEGER_BASE_URL"),
                timeout: Float(ENV.fetch("TRACE_EXPORT_TIMEOUT_SECONDS", "60"))).archive(
                  trace_id: result.fetch(:trace_id), parent_id: result.fetch(:initiating_span_id), output: File.join(directory, "trace.json"))
              result[:trace_status] = archive.fetch(:status)
              failed ||= archive.fetch(:status) != "archived"
            end
            File.write(File.join(directory, "result.json"), JSON.pretty_generate(result))
            csv << [label, phase, run + 1, mode, result[:outcome], result[:duration_seconds], result[:request_count], result[:response_bytes], result[:trace_id], directory]
            csv.flush
            failed ||= result.fetch(:outcome) != "ok"
            puts "#{label} #{phase} #{mode} run=#{run + 1}: #{result[:outcome]} #{result[:duration_seconds].round(3)}s requests=#{result[:request_count]}"
            $stdout.flush
          end
        end
      end
    end
  end
  exit(failed ? 1 : 0)
end
