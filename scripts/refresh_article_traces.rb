#!/usr/bin/env ruby
# frozen_string_literal: true

# Run from any directory: ruby scripts/refresh_article_traces.rb [--plan]
# Defaults to prod; BENCHMARK_STACK=dev selects dev. Builds current instrumentation
# unless SKIP_BUILD=1. Uses existing seeded fixtures, recreates app containers with
# each case's settings, and flushes cache DB 1 for cold samples. Leaves the final
# case's configuration running. No seeding, ANALYZE, load tests or full MSP walks.
# CASE_IDS is an optional comma-separated subset for rerunning unfinished cases.
# COLLECTION_DIR selects a NEW output directory. Commit runtime code before running.
# Each configuration is warmed before measurements. Only Redis DB 1 is flushed;
# Rails processes and PostgreSQL caches stay warm. Reselect NEW subtree span IDs.

require_relative "collect_article_evidence"
require_relative "benchmark_hierarchies"
require_relative "benchmark_response"
require_relative "authorization_correctness_gate"
require_relative "gallery_correctness"
require_relative "workload_trace"

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
        notes: ["#{@cases.sum { |item| CASES.fetch(item.fetch("id")).size }} exports; first organization/MSP page only", "Two workload warmups per profile precede all measurements; Redis alone is flushed for cold samples",
                "Hierarchy record /can retains the depth-25 walk", "Build committed runtime code; no seed, ANALYZE, or PostgreSQL restart"])
      return
    end
    dirty_code = capture("git", "diff", "HEAD", "--name-only", "--", "*-service", "scripts").strip
    raise "Commit runtime/collector changes before collecting: #{dirty_code}" unless dirty_code.empty? || ENV["GALLERY_CORRECTNESS_REVIEW"] == "1"
    raise "Missing fixture manifest: #{@manifest}" unless File.file?(@manifest)
    raise "Output already exists; choose a new COLLECTION_DIR: #{@out}" if File.exist?(@out)
    seed_manifest = JSON.parse(File.read(@manifest))
    @seed_profile = seed_manifest.fetch('profile', 'full')
    @fixtures = seed_manifest.fetch("fixtures").to_h { |f| [f.fetch("name"), f] }
    %w[deep_chain wide_org massive_fanout_10k].each { |name| @fixtures.fetch(name) }
    FileUtils.mkdir_p(@out)
    FileUtils.cp(@manifest, File.join(@out, "fixture_manifest.json"))
    write_json(File.join(@out, "collection.json"), @fingerprint.merge("started_at" => Time.now.utc.iso8601,
      "purpose" => "Selected article traces only; not replacement benchmark timings",
      "instrumentation" => { "automatic" => %w[Net::HTTP Rack GraphQL], "sql" => "application sql.active_record executions only",
        "redis" => "one span per application pipeline", "workload_root" => true,
        "controller_http_phases_serialization_materialization_spans" => false, "application_cache_spans" => false, "authorization_spans" => true,
        "solid_cache" => false, "active_record_query_cache" => true, "workload_warmups_per_profile" => 2,
        "cold_cache_policy" => "Redis DB 1 only; no Rails or PostgreSQL restart" },
      "working_tree_status" => capture("git", "status", "--short"), "cases" => @cases))
    File.write(File.join(@out, "working-tree.patch"), capture("git", "diff", "HEAD", "--", ".", ":(exclude)*.env"))
    source_files = Dir.glob("{*-service,scripts}/**/*", File::FNM_DOTMATCH).select { |p| File.file?(p) && !p.match?(%r{/(?:\.git|tmp|log|storage|node_modules)/}) }
    write_json(File.join(@out, "source-sha256.json"), source_files.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] })
    untracked = capture("git", "ls-files", "--others", "--exclude-standard", "--", "*-service", "scripts").lines.map(&:strip)
    untracked.each { |p| target = File.join(@out, "untracked-source", p); FileUtils.mkdir_p(File.dirname(target)); FileUtils.cp(p, target) }
    puts "Trace refresh: #{@out}"
    command({}, File.join(@out, "ports.log"), "ruby", "scripts/check_stack_ports.rb")
    unless ENV.fetch("SKIP_BUILD", "0") == "1"
      command({}, File.join(@out, "build.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "build", *APPS.reject { |app| app.end_with?("-auth-service") })
    end
    databases = capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "config", "--services").split.select { |name| name.match?(/-db(?:-|$)/) }
    command({}, File.join(@out, "infra.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "up", "-d", "--wait", "--no-recreate", *(INFRA + databases).uniq)
    running = capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "ps", "--status", "running", "--services").split
    workers = running.grep(/-create-service-worker-/)
    raise "Stop seed workers before collection: #{workers.join(', ')}" unless workers.empty?
    write_json(File.join(@out, "worker-state.json"), { checked_at: Time.now.utc.iso8601, running_seed_workers: workers,
      running_services: running })
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
        AuthorizationCorrectnessGate.new(settings: @stack_env).run(output: File.join(@directory, "authorization-gate.json"))
        @warm_processes = rails_processes
        warm_case(item)
        verify_warm_processes!("after-warmup")
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
        verify_warm_processes!("after-measurement") if @warm_processes
        @warm_processes = nil
        # No trace polling between a prime and its warm request.
        @pending.each do |entry|
          status = TraceArchive.new(base_url: @stack_env.fetch("JAEGER_BASE_URL"),
            timeout: Float(ENV.fetch("TRACE_EXPORT_TIMEOUT_SECONDS", "120")),
            quiet_seconds: Float(ENV.fetch("TRACE_QUIET_SECONDS", "5"))).archive(
              trace_id: entry.fetch(:trace_id), parent_id: entry.fetch(:parent_id), output: entry.fetch(:output), require_root: true)
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

  def rails_processes
    probe = 'puts Dir["/proc/[0-9]*/cmdline"].filter_map { |path| pid=path.split("/")[2].to_i; next if pid==Process.pid; command=File.read(path).tr("\\0", " "); next unless command.start_with?("puma ", "ruby bin/rails", "ruby /rails/bin/rails"); [pid,File.read("/proc/#{pid}/stat").split[21]] rescue nil }.sort.to_json'
    APPS.to_h do |service|
      processes = JSON.parse(capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "ruby", "-rjson", "-e", probe))
      raise "Cannot identify Rails process: #{service}" if processes.empty?
      [service, processes]
    end
  end

  def verify_warm_processes!(phase)
    current = rails_processes
    write_json(File.join(@directory, "processes-#{phase}.json"), current)
    raise "Rails process changed during warmup/measurement" unless current == @warm_processes
  end

  def flush_redis(label)
    %w[accountcache authcache groupcache orgcache].each do |service|
      command(@env, File.join(@directory, "flush-#{label}-#{service}.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "redis-cli", "-n", "1", "FLUSHDB")
    end
  end

  def warm_case(item)
    write_json(File.join(@directory, "processes-before-warmup.json"), @warm_processes)
    # Exercise misses as well as hits before the measured Redis flush.
    flush_redis("before-warmup") if item.fetch("redis") == "true"
    outcomes = []
    2.times do |round|
      prefix = "warmup-#{round + 1}"
      puts "Warming #{item.fetch('id')} (#{round + 1}/2)"
      if item.fetch("id") == "hierarchies-redis-off"
        [["walk", 5], ["cte", 5], ["individual", nil], ["batch", nil], ["walk", 25]].each_with_index do |(mode, depth), index|
          outcomes << hierarchy("#{prefix}-#{index}-#{mode}", mode, depth: depth, archive: false)
        end
      else
        args = item.fetch("id").start_with?("graphql-") ? graphql_request(item.fetch("id") == "graphql-cache-b200") : organization_request(item.fetch("fixture"))
        outcomes << request(prefix, *args, archive: false, warmup: true)
      end
    end
    write_json(File.join(@directory, "warmup-results.json"), outcomes)
  end

  def actor(fixture)
    targets = fixture.fetch("targets")
    value = targets.fetch("top_level_admin_user_id") { targets.fetch("admin_user_id") }
    raise "A real actor is required" if value.empty? || value.start_with?("IAM_SYSTEM")
    value
  end

  def workload_trace(id, fixture, hierarchy_mode: nil, depth: nil, target_count: nil)
    redis = @case.fetch('redis') == 'true'
    phase = if !redis
      'off'
    elsif id.start_with?('warmup')
      'warmup'
    elsif id.end_with?('-cold')
      'cold'
    elsif id.end_with?('-prime')
      'prime'
    else
      'warm'
    end
    intent = if hierarchy_mode
      case hierarchy_mode
      when 'walk' then "Walk #{depth} parent accounts"
      when 'cte' then "Load #{depth}-level hierarchy with CTE"
      when 'individual' then "Load #{target_count} hierarchies individually"
      when 'batch' then "Load #{target_count} hierarchies in one batch"
      end
    elsif @case.fetch('id') == 'graphql-cache-b200'
      'GraphQL MSP users and groups'
    elsif @case.fetch('id').start_with?('graphql-')
      'GraphQL hierarchy users and groups'
    else
      'Load organization users and groups'
    end
    fixture_name = fixture.fetch('name')
    name = "#{intent} | #{@seed_profile}/#{fixture_name} (#{fixture.fetch('user_count')} users) | #{@case.fetch('auth')} | Redis #{phase} | #{@case.fetch('retrieval')} #{@case.fetch('batch_size')}"
    name = "Warmup: #{name}" if id.start_with?('warmup')
    attributes = {
      'workload.intent' => intent, 'workload.case' => @case.fetch('id'), 'workload.sample' => id,
      'workload.collection' => File.basename(@out), 'workload.stack' => @stack_env.fetch('BENCHMARK_STACK'),
      'workload.revision' => @revision, 'fixture.name' => fixture_name,
      'fixture.profile' => @seed_profile, 'workload.warmup' => id.start_with?('warmup'),
      'fixture.account_count' => fixture.fetch('account_count'), 'fixture.user_count' => fixture.fetch('user_count'),
      'authorization.mode' => @case.fetch('auth'), 'redis.enabled' => redis, 'redis.phase' => phase,
      'retrieval.mode' => @case.fetch('retrieval'), 'retrieval.batch_size' => @case.fetch('batch_size'),
      'hierarchy.method' => hierarchy_mode, 'hierarchy.depth' => depth, 'hierarchy.target_count' => target_count
    }.compact
    WorkloadTrace.new(endpoint: @stack_env.fetch('OTEL_COLLECTOR_BASE_URL'), name: name, attributes: attributes)
  end

  def enqueue(id, trace_id, parent_id, output)
    entry = { id: id, case: @case.fetch("id"), trace_id: trace_id, parent_id: parent_id,
      output: output, kind: id.start_with?("authorization-") ? "subtree-source" : "complete", status: "pending" }
    @index << entry
    @pending << entry
    write_json(File.join(@out, "trace-index.json"), @index)
  end

  def hierarchy(id, mode, depth: nil, archive: true)
    fixture = @fixtures.fetch("deep_chain")
    ids = fixture.fetch("accounts").map { |account| account.fetch("id") }
    ids = depth ? [ids.find { |target| HierarchyComparison.expected_chain(fixture, target).size == depth } || raise("Missing depth #{depth}")] : ids.last(8)
    directory = File.join(@directory, id)
    workload = workload_trace(id, fixture, hierarchy_mode: mode, depth: depth, target_count: ids.size)
    result = HierarchyComparison.new(base_url: @stack_env.fetch("ACCOUNT_SERVICE_BASE_URL"), actor: actor(fixture),
      batch_size: 1000, timeout: Float(ENV.fetch("REQUEST_TIMEOUT_SECONDS", "600"))).measure(
        mode: mode, target_ids: ids, expected: ids.to_h { |target| [target, HierarchyComparison.expected_chain(fixture, target)] }, directory: directory)
    workload.stop
    result[:trace_name] = workload.export(trace_id: result.fetch(:trace_id), span_id: result.fetch(:initiating_span_id), outcome: result.fetch(:outcome))
    write_json(File.join(directory, "result.json"), result)
    raise "Hierarchy failed: #{id}: #{result}" unless result.fetch(:outcome) == "ok"
    if archive
      enqueue(id, result.fetch(:trace_id), result.fetch(:initiating_span_id), File.join(directory, "trace.json"))
      @index.last[:trace_name] = result.fetch(:trace_name)
    end
    result
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
    flush_redis("measured-cold")
    request("#{prefix}-cold", *args)
    request("#{prefix}-prime", *args, archive: false)
    request("#{prefix}-warm", *args)
  end

  def request(id, method, url, body, archive: true, warmup: false)
    directory = File.join(@directory, id)
    FileUtils.mkdir_p(directory)
    response_file = File.join(directory, "response.json")
    trace_id, parent_id = SecureRandom.hex(16), SecureRandom.hex(8)
    args = ["curl", "-sS", "--max-time", ENV.fetch("REQUEST_TIMEOUT_SECONDS", "600"),
      "-H", "traceparent: 00-#{trace_id}-#{parent_id}-01", "-D", File.join(directory, "headers.txt"),
      "-o", response_file, "-w", "%{http_code} %{time_total}"]
    if body
      payload = File.join(directory, "request.json")
      write_json(payload, body)
      args += ["-X", method, "-H", "Content-Type: application/json", "--data-binary", "@#{payload}"]
    end
    fixture_name = body ? (@case.fetch('id') == 'graphql-cache-b200' ? 'massive_fanout_10k' : 'deep_chain') : @case.fetch('fixture')
    workload = workload_trace(id, @fixtures.fetch(fixture_name))
    timing, error, status = Open3.capture3(*args, url)
    workload.stop
    code, elapsed = timing.split
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
    if result["outcome"] == "ok"
      fixture_name = body ? (@case.fetch("id") == "graphql-cache-b200" ? "massive_fanout_10k" : "deep_chain") : @case.fetch("fixture")
      begin
        result["correctness"] = GalleryCorrectness.validate(File.read(response_file), fixture: @fixtures.fetch(fixture_name), batch_size: @case.fetch("batch_size"), graphql: !body.nil?)
      rescue StandardError => error
        result.merge!("outcome" => "correctness_failure", "correctness_error" => error.message)
      end
    end
    result.merge!("trace_id" => trace_id, "url" => url, "http_status" => code.to_i,
      "client_elapsed_seconds" => Float(elapsed), "warmup" => warmup)
    result['trace_name'] = workload.export(trace_id: trace_id, span_id: parent_id, outcome: result.fetch('outcome'))
    write_json(File.join(directory, "result.json"), result)
    if archive
      enqueue(id, trace_id, parent_id, File.join(directory, "trace.json"))
      @index.last[:request_outcome] = result.fetch("outcome")
      @index.last[:trace_name] = result.fetch('trace_name')
      @index.last[:publishable] = ENV["GALLERY_CORRECTNESS_REVIEW"] != "1" && archive && result.fetch("outcome") == "ok"
      write_json(File.join(@out, "trace-index.json"), @index)
    end
    if warmup
      settled = TraceArchive.new(base_url: @stack_env.fetch("JAEGER_BASE_URL"), timeout: 180, quiet_seconds: 5).archive(
        trace_id: trace_id, parent_id: parent_id, output: File.join(directory, "trace.json"), require_root: true)
      raise "Warmup did not settle: #{id}: #{settled}" unless settled.fetch(:status) == "archived"
    elsif result.fetch("outcome") != "ok"
      raise "Request failed: #{id}: #{result}; see #{directory}"
    end
    result
  end
end

if $PROGRAM_NAME == __FILE__
  Dir.chdir(File.expand_path("..", __dir__)) { ArticleTraceRefresh.new.run }
end
