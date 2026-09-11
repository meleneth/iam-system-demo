#!/usr/bin/env ruby
# frozen_string_literal: true

# Run from any directory: ruby scripts/refresh_article_traces.rb [--plan]
# Defaults to prod; BENCHMARK_STACK=dev selects dev. Builds current instrumentation
# unless SKIP_BUILD=1. Uses existing seeded fixtures, recreates app containers with
# each case's settings, and flushes cache DB 1 for cold samples. Leaves the final
# case's configuration running. No seeding, ANALYZE, load tests or full MSP walks.
# CASE_IDS is an optional comma-separated subset for rerunning unfinished cases.
# COLLECTION_DIR selects a NEW output directory. Dirty instrumentation is allowed
# and recorded. Authorization excerpts must be reselected using NEW span IDs.

require_relative "collect_article_evidence"
require_relative "benchmark_hierarchies"
require_relative "benchmark_response"

class ArticleTraceRefresh < ArticleCollection
  CASES = {
    "hierarchies-redis-off" => %w[hierarchy-walk hierarchy-cte hierarchy-individual hierarchy-batch authorization-record-can],
    "retrieval-deep-serial" => %w[authorization-record-capabilities],
    "retrieval-wide-batched" => %w[authorization-collection-capabilities],
    "auth-wide-can" => %w[authorization-collection-can],
    "cache-wide-can" => %w[organization-cold organization-warm],
    "graphql-cache-b1000" => %w[graphql-cold graphql-warm],
    "graphql-cache-b200" => %w[graphql-msp]
  }.freeze

  def initialize
    super
    @out = File.expand_path(ENV.fetch("COLLECTION_DIR", "reports/raw/article-traces-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"))
    @cases = CASES.keys.map { |id| @matrix.fetch("cases").find { |item| item.fetch("id") == id } || raise("Missing matrix case #{id}") }
    selected = ENV["CASE_IDS"]&.split(",")
    raise "Unknown CASE_IDS: #{(selected - CASES.keys).join(', ')}" if selected && (selected - CASES.keys).any?
    @cases.select! { |item| selected.include?(item.fetch("id")) } if selected
    raise "CASE_IDS selected no cases" if @cases.empty?
    @index, @pending, @failures = [], [], []
  end

  def run
    raise "Usage: ruby scripts/refresh_article_traces.rb [--plan]" unless (ARGV - ["--plan"]).empty?
    if ARGV.include?("--plan")
      puts JSON.pretty_generate(stack: @stack_env.fetch("BENCHMARK_STACK"), output: @out,
        cases: @cases.map { |item| item.merge("runs" => 1, "examples" => CASES.fetch(item.fetch("id"))) },
        notes: ["#{@cases.sum { |item| CASES.fetch(item.fetch("id")).size }} exports; first organization/MSP page only", "Warm samples get an immediate prime; primes are not archived",
                "Hierarchy record /can retains the depth-25 walk", "Build current working tree; no seed or ANALYZE"])
      return
    end
    raise "Missing fixture manifest: #{@manifest}" unless File.file?(@manifest)
    raise "Output already exists; choose a new COLLECTION_DIR: #{@out}" if File.exist?(@out)
    @fixtures = JSON.parse(File.read(@manifest)).fetch("fixtures").to_h { |f| [f.fetch("name"), f] }
    %w[deep_chain wide_org massive_fanout_10k].each { |name| @fixtures.fetch(name) }
    FileUtils.mkdir_p(@out)
    FileUtils.cp(@manifest, File.join(@out, "fixture_manifest.json"))
    write_json(File.join(@out, "collection.json"), @fingerprint.merge("started_at" => Time.now.utc.iso8601,
      "purpose" => "Selected article traces only; not replacement benchmark timings",
      "working_tree_status" => capture("git", "status", "--short"), "cases" => @cases))
    File.write(File.join(@out, "working-tree.patch"), capture("git", "diff", "HEAD", "--", ".", ":(exclude)*.env"))
    puts "Trace refresh: #{@out}"
    command({}, File.join(@out, "ports.log"), "ruby", "scripts/check_stack_ports.rb")
    unless ENV.fetch("SKIP_BUILD", "0") == "1"
      command({}, File.join(@out, "build.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "build", *APPS.reject { |app| app == "account-auth-service" })
    end
    databases = capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "config", "--services").split.select { |name| name.match?(/-db(?:-|$)/) }
    command({}, File.join(@out, "infra.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "up", "-d", "--wait", *(INFRA + databases).uniq)
    @cases.each do |item|
      @case = item
      @directory = File.join(@out, item.fetch("id"), "attempt-001")
      FileUtils.mkdir_p(@directory)
      begin
        @env = @stack_env.merge(ArticleCollection.case_environment(item, @directory, @manifest, 1))
        puts "Collecting #{item.fetch('id')}: #{CASES.fetch(item.fetch('id')).join(', ')}"
        command(@env, File.join(@directory, "startup.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "up", "-d", "--no-deps", *APPS)
        wait_for_apps(@env)
        config = runtime_configuration(@env)
        verify_configuration!(item, config)
        write_json(File.join(@directory, "runtime.json"), config)
        case item.fetch("id")
        when "hierarchies-redis-off"
          hierarchy("hierarchy-walk", "walk", depth: 5)
          hierarchy("hierarchy-cte", "cte", depth: 5)
          hierarchy("hierarchy-individual", "individual")
          hierarchy("hierarchy-batch", "batch")
          hierarchy("authorization-record-can", "walk", depth: 25)
        when "retrieval-deep-serial", "retrieval-wide-batched", "auth-wide-can"
          request(CASES.fetch(item.fetch("id")).first, *organization_request(item.fetch("fixture")))
        when "cache-wide-can"
          cold_warm("organization", organization_request("wide_org"))
        when "graphql-cache-b1000"
          cold_warm("graphql", graphql_request(false))
        when "graphql-cache-b200"
          args = graphql_request(true)
          request("graphql-msp-prime", *args, archive: false)
          request("graphql-msp", *args)
        end
      rescue StandardError => error
        @failures << { case: item.fetch("id"), error: error.message }
        warn "#{item.fetch('id')} failed: #{error.message}; saving diagnostics and continuing"
        system(@stack_env.fetch("BENCHMARK_WRAPPER"), "logs", "--no-color", "--tail", "200", *APPS,
          out: File.join(@directory, "failure-services.log"), err: [:child, :out])
        write_json(File.join(@directory, "failure.json"), @failures.last)
      ensure
        # No trace polling between a prime and its warm request.
        @pending.each do |entry|
          status = TraceArchive.new(base_url: @stack_env.fetch("JAEGER_BASE_URL"),
            timeout: Float(ENV.fetch("TRACE_EXPORT_TIMEOUT_SECONDS", "120")),
            quiet_seconds: Float(ENV.fetch("TRACE_QUIET_SECONDS", "5"))).archive(
              trace_id: entry.fetch(:trace_id), parent_id: entry.fetch(:parent_id), output: entry.fetch(:output))
          entry[:status] = status.fetch(:status)
          write_json(File.join(@out, "trace-index.json"), @index)
          unless status.fetch(:status) == "archived"
            @failures << { case: item.fetch("id"), error: "Trace export failed: #{entry.fetch(:id)}" }
          end
        end
        @pending.clear
      end
    end
    write_json(File.join(@out, "collection_status.json"), { failures: @failures, traces: @index.size })
    unless @failures.empty?
      warn "Collection has failures; inspect #{@out}/collection_status.json. Rerun cases with CASE_IDS=#{@failures.map { |f| f.fetch(:case) }.uniq.join(',')} and a new COLLECTION_DIR."
      exit 1
    end
    puts "Saved #{@index.size} source traces to #{@out}; see trace-index.json. Reselect authorization subtree roots before importing."
  end

  private

  def actor(fixture)
    targets = fixture.fetch("targets")
    value = targets.fetch("top_level_admin_user_id") { targets.fetch("admin_user_id") }
    raise "A real actor is required" if value.empty? || value.start_with?("IAM_SYSTEM")
    value
  end

  def enqueue(id, trace_id, parent_id, output)
    entry = { id: id, case: @case.fetch("id"), trace_id: trace_id, parent_id: parent_id,
      output: output, kind: id.start_with?("authorization-") ? "subtree-source" : "complete", status: "pending" }
    @index << entry
    @pending << entry
    write_json(File.join(@out, "trace-index.json"), @index)
  end

  def hierarchy(id, mode, depth: nil)
    fixture = @fixtures.fetch("deep_chain")
    ids = fixture.fetch("accounts").map { |account| account.fetch("id") }
    ids = depth ? [ids.find { |target| HierarchyComparison.expected_chain(fixture, target).size == depth } || raise("Missing depth #{depth}")] : ids.last(8)
    directory = File.join(@directory, id)
    result = HierarchyComparison.new(base_url: @stack_env.fetch("ACCOUNT_SERVICE_BASE_URL"), actor: actor(fixture),
      batch_size: 1000, timeout: Float(ENV.fetch("REQUEST_TIMEOUT_SECONDS", "600"))).measure(
        mode: mode, target_ids: ids, expected: ids.to_h { |target| [target, HierarchyComparison.expected_chain(fixture, target)] }, directory: directory)
    write_json(File.join(directory, "result.json"), result)
    raise "Hierarchy failed: #{id}: #{result}" unless result.fetch(:outcome) == "ok"
    enqueue(id, result.fetch(:trace_id), result.fetch(:initiating_span_id), File.join(directory, "trace.json"))
  end

  def organization_request(name)
    fixture = @fixtures.fetch(name)
    query = URI.encode_www_form(organization_id: fixture.fetch("organization_id"), as: actor(fixture), frame_id: "benchmark-partition-root")
    ["GET", "#{@stack_env.fetch('USER_MANAGEMENT_BASE_URL')}/organization_user_management/partition?#{query}", nil]
  end

  def graphql_request(msp)
    fixture = @fixtures.fetch(msp ? "massive_fanout_10k" : "deep_chain")
    target = fixture.fetch("targets").fetch(msp ? "msp_account_id" : "leaf_account_id")
    query = if msp
      "{ mspUserManagement(mspAccountId: #{target.to_json}, as: #{actor(fixture).to_json}) { loading loadedCount totalCount continuance message accounts { id users { id email accountId groups { id name } } } } }"
    else
      "{ accountWithParents(id: #{target.to_json}, as: #{actor(fixture).to_json}) { id name parentAccountId users { id email accountId groups { id name } } } }"
    end
    ["POST", "#{@stack_env.fetch('USER_MANAGEMENT_BASE_URL')}/graphql", { query: query }]
  end

  def cold_warm(prefix, args)
    %w[accountcache authcache groupcache orgcache].each do |service|
      command(@env, File.join(@directory, "flush-#{service}.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "redis-cli", "-n", "1", "FLUSHDB")
    end
    request("#{prefix}-cold", *args)
    request("#{prefix}-prime", *args, archive: false)
    request("#{prefix}-warm", *args)
  end

  def request(id, method, url, body, archive: true)
    directory = File.join(@directory, id)
    FileUtils.mkdir_p(directory)
    response_file = File.join(directory, "response.json")
    trace_id, parent_id = SecureRandom.hex(16), SecureRandom.hex(8)
    args = ["curl", "-sS", "--max-time", ENV.fetch("REQUEST_TIMEOUT_SECONDS", "600"),
      "-H", "traceparent: 00-#{trace_id}-#{parent_id}-01", "-D", File.join(directory, "headers.txt"),
      "-o", response_file, "-w", "%{http_code}"]
    if body
      payload = File.join(directory, "request.json")
      write_json(payload, body)
      args += ["-X", method, "-H", "Content-Type: application/json", "--data-binary", "@#{payload}"]
    end
    code, error, status = Open3.capture3(*args, url)
    File.write(File.join(directory, "curl-error.txt"), error)
    result = BenchmarkResponse.inspect_response(response_file, http_code: code.to_i,
      curl_exit: status.exitstatus || 1, partition: body.nil?, graphql: !body.nil?)
    if result["outcome"] == "ok" && body.nil?
      raise "Partition configuration mismatch" unless result["retrieval_mode"] == @case.fetch("retrieval") && result["batch_size"] == @case.fetch("batch_size")
    end
    if result["outcome"] == "ok" && id.start_with?("graphql-msp")
      page = JSON.parse(File.read(response_file)).fetch("data").fetch("mspUserManagement")
      result["outcome"] = "msp_page_not_ready" if page["loading"] || Array(page["accounts"]).empty?
    end
    write_json(File.join(directory, "result.json"), result.merge("trace_id" => trace_id, "url" => url))
    if archive || result.fetch("outcome") != "ok"
      enqueue(id, trace_id, parent_id, File.join(directory, "trace.json"))
      @index.last[:request_outcome] = result.fetch("outcome")
      @index.last[:publishable] = archive && result.fetch("outcome") == "ok"
      write_json(File.join(@out, "trace-index.json"), @index)
    end
    # The instrumented wide capabilities request is expected to return an empty
    # reply. Retain its trace as failure evidence without aborting collection.
    expected_failure = @case.fetch("id") == "retrieval-wide-batched" &&
      result["outcome"] == "transport_error" && result["curl_exit"] == 52
    if expected_failure
      @index.last[:expected_failure] = true
      write_json(File.join(@out, "trace-index.json"), @index)
      warn "#{id}: expected empty reply; archiving the failed-request trace and continuing"
    elsif result.fetch("outcome") != "ok"
      raise "Request failed: #{id}: #{result}; see #{directory}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Dir.chdir(File.expand_path("..", __dir__)) { ArticleTraceRefresh.new.run }
end
