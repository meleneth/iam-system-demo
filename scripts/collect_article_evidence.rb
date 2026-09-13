# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "digest"
require "time"
require_relative "benchmark_environment"

class ArticleCollection
  APPS = %w[user-management-service account-service account-auth-service authorization-service organization-service organization-auth-service user-service group-service group-auth-service].freeze
  INFRA = %w[user-db account-db authz-db organization-db group-db accountcache authcache orgcache groupcache otel-collector jaeger].freeze
  CONFIG_KEYS = %w[RAILS_ENV RAILS_MAX_THREADS RAILS_MIN_THREADS WEB_CONCURRENCY IAM_DEMO_BATCH_SIZE IAM_DEMO_RETRIEVAL_MODE GLOBAL_IAM_DEMO_USE_REDIS AUTHORIZATION_CHECK_MODE ACCOUNT_SERVICE_API_BASE_URL AUTHORIZATION_SERVICE_API_BASE_URL ORGANIZATION_SERVICE_API_BASE_URL GROUP_SERVICE_API_BASE_URL].freeze

  def initialize
    @stack_env = BenchmarkEnvironment.values
    @matrix = JSON.parse(File.read("benchmarks/article_matrix.json"))
    @out = File.expand_path(ENV.fetch("COLLECTION_DIR", "reports/raw/article-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"))
    @manifest = File.expand_path(@stack_env.fetch("MANIFEST"))
    @revision = capture("git", "rev-parse", "HEAD").strip
    @fingerprint = { "revision" => @revision, "matrix_sha256" => Digest::SHA256.file("benchmarks/article_matrix.json").hexdigest,
      "stack" => @stack_env.fetch("BENCHMARK_STACK"), "benchmark_environment" => @stack_env,
      "manifest_sha256" => File.file?(@manifest) ? Digest::SHA256.file(@manifest).hexdigest : nil }
  end

  def run
    if ARGV.include?("--plan")
      puts JSON.pretty_generate(@matrix.merge("stack" => @stack_env.fetch("BENCHMARK_STACK"), "manifest" => @manifest))
      return
    end
    raise "Missing fixture manifest: #{@manifest}; prepare this stack’s data first" unless File.file?(@manifest)
    raise "Commit or stash tracked changes before collecting" unless capture("git", "diff", "HEAD", "--name-only").strip.empty?
    FileUtils.mkdir_p(@out)
    lock = File.open(File.join(@out, "collection.lock"), "w")
    raise "This collection is already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    metadata_path = File.join(@out, "collection.json")
    if File.exist?(metadata_path)
      previous = JSON.parse(File.read(metadata_path))
      raise "Revision, matrix, or fixture changed; use a new COLLECTION_DIR" unless @fingerprint.all? { |key, value| previous[key] == value }
    else
      write_json(metadata_path, @fingerprint.merge("started_at" => Time.now.utc.iso8601,
        "uname" => capture("uname", "-a").strip, "cpu" => capture("lscpu", "-J"),
        "memory" => File.read("/proc/meminfo"), "display" => ENV["DISPLAY"], "session_type" => ENV["XDG_SESSION_TYPE"]))
      FileUtils.cp(@manifest, File.join(@out, "fixture_manifest.json"))
      FileUtils.cp("benchmarks/article_matrix.json", File.join(@out, "matrix.json"))
    end
    puts "Collection: #{@out}"
    puts "Revision: #{@revision}"
    $stdout.flush
    command({}, File.join(@out, "ports.log"), "ruby", "scripts/check_stack_ports.rb")
    unless ENV.fetch("SKIP_BUILD", "0") == "1"
      command({}, File.join(@out, "build.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "build", *APPS.reject { |app| app.end_with?("-auth-service") })
    end
    command({}, File.join(@out, "startup.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "up", "-d", "--wait", *(INFRA + capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "config", "--services").split.select { |name| name.match?(/-db(?:-|$)/) }).uniq)
    # Existing queue-drain convention is accepted; do not reseed or reconcile data.
    command({}, File.join(@out, "analyze.log"), "./analyze_databases.sh", @stack_env.fetch("BENCHMARK_STACK"))
    selected = ENV["CASE_IDS"]&.split(",")
    raise "Unknown CASE_IDS" if selected && (selected - @matrix.fetch("cases").map { |item| item.fetch("id") }).any?
    @matrix.fetch("cases").each do |item|
      next if selected && !selected.include?(item.fetch("id"))
      directory = File.join(@out, item.fetch("id"))
      completion = File.join(directory, "completed.json")
      if File.exist?(completion)
        previous = JSON.parse(File.read(completion))
        next unless ENV["RETRY_FAILED"] == "1" && !previous.fetch("success")
      end
      unless item["smoke"]
        @matrix.fetch("cases").select { |candidate| candidate["smoke"] }.each do |gate|
          gate_path = File.join(@out, gate.fetch("id"), "completed.json")
          unless File.exist?(gate_path) && JSON.parse(File.read(gate_path)).fetch("success")
            raise "Smoke gate #{gate.fetch('id')} must pass in this collection before measured cases"
          end
        end
      end
      FileUtils.mkdir_p(directory)
      attempt = Dir.glob(File.join(directory, "attempt-*")).size + 1
      attempt_dir = File.join(directory, format("attempt-%03d", attempt))
      FileUtils.mkdir_p(attempt_dir)
      env = case_environment(item, attempt_dir)
      puts "Starting #{item.fetch('id')} (attempt #{attempt})"
      $stdout.flush
      command(env, File.join(attempt_dir, "startup.log"), @stack_env.fetch("BENCHMARK_WRAPPER"), "up", "-d", "--no-deps", *APPS)
      wait_for_apps(env)
      configurations = runtime_configuration(env)
      verify_configuration!(item, configurations)
      write_json(File.join(attempt_dir, "runtime.json"), configurations)
      containers = capture(@stack_env.fetch("BENCHMARK_WRAPPER"), "ps", "-q", *APPS).split
      write_json(File.join(attempt_dir, "images.json"), containers.map { |id|
        capture("docker", "inspect", "--format", '{{.Name}} {{.Image}} {{.State.Pid}}', id).strip
      })
      before = Time.now.utc.iso8601
      driver = item.fetch("driver") == "hierarchies" ? "./benchmark_hierarchies.sh" : "./benchmark_demo.sh"
      success, exit_code = run_driver(env, driver, File.join(attempt_dir, "run.log"))
      status = { "case" => item.fetch("id"), "attempt" => attempt, "started_at" => before,
        "finished_at" => Time.now.utc.iso8601, "exit_code" => exit_code,
        "success" => success, "output" => attempt_dir }
      write_json(File.join(attempt_dir, "status.json"), status)
      # Record non-smoke failures as observations; do not pretend they succeeded.
      if item["smoke"] && !success
        raise "Smoke gate failed: #{item.fetch('id')}; inspect #{attempt_dir}/run.log"
      end
      write_json(completion, status)
      puts "Finished #{item.fetch('id')}: #{success ? 'ok' : 'failed samples retained'}"
      $stdout.flush
    end
    statuses = Dir.glob(File.join(@out, "*", "completed.json")).map { |path| JSON.parse(File.read(path)) }
    failures = statuses.reject { |status| status.fetch("success") }.map { |status| status.fetch("case") }
    write_json(File.join(@out, "collection_status.json"), { "completed_cases" => statuses.size, "failed_cases" => failures })
    puts "Collection finished: #{statuses.size} completed cases; #{failures.size} with failed samples. Evidence: #{@out}"
    exit 1 unless failures.empty?
  ensure
    lock&.close
  end

  def self.case_environment(item, out, manifest, runs)
    { "OUT_DIR" => out, "MANIFEST" => manifest, "GLOBAL_IAM_DEMO_USE_REDIS" => item.fetch("redis"),
      "AUTHORIZATION_CHECK_MODE" => item.fetch("auth"), "IAM_DEMO_RETRIEVAL_MODE" => item.fetch("retrieval"),
      "IAM_DEMO_BATCH_SIZE" => item.fetch("batch_size").to_s, "RUNS" => item.fetch("runs", runs).to_s,
      "ARCHIVE_TRACES" => "1", "REDIS_CACHE_DB" => "1", "CACHE_WAIT_SECONDS" => "0",
      "GRAFANA_ANNOTATIONS_ENABLED" => "0", "INCLUDE_EXPERIMENTAL" => "0",
      "REQUEST_TIMEOUT_SECONDS" => (item.fetch("retrieval") == "serial" ? 180 : 600).to_s,
      "FOCUSED_ORGANIZATION_ONLY" => item.fetch("driver") == "organization" ? "1" : "0",
      "ORGANIZATION_FIXTURE" => item.fetch("fixture", "wide_org"),
      "COLD_ONLY" => item.fetch("redis") == "false" ? "1" : "0",
      "INCLUDE_MSP_100K" => item.fetch("fanout_100k", true) ? "1" : "0",
      "INCLUDE_MSP_50K" => item.fetch("fanout_50k", true) ? "1" : "0", "INCLUDE_MSP_10K" => "1",
      "EXPERIMENT" => item.fetch("experiment", "all"), "DEPTHS" => item.fetch("depths", "1,5,10,25") }
  end

  private

  def case_environment(item, out)
    @stack_env.merge(self.class.case_environment(item, out, @manifest, @matrix.fetch("runs")))
  end

  def run_driver(env, driver, log)
    success = system(env, driver, out: log, err: [:child, :out])
    [success, $?.exitstatus]
  end

  def command(env, log, *args)
    raise "Command failed: #{args.join(' ')}; see #{log}" unless system(env, *args, out: log, err: [:child, :out])
  end

  def capture(*args)
    output, status = Open3.capture2e(*args)
    raise "Command failed: #{args.join(' ')}: #{output}" unless status.success?
    output
  end

  def wait_for_apps(env)
    APPS.each do |service|
      ready = false
      90.times do
        if system(env, @stack_env.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "curl", "-fsS", "--max-time", "2", "http://localhost:3000/up", out: File::NULL, err: File::NULL)
          ready = true
          break
        end
        sleep 1
      end
      raise "Service never became ready: #{service}" unless ready
    end
  end

  def runtime_configuration(env)
    APPS.to_h do |service|
      output, status = Open3.capture2e(env, @stack_env.fetch("BENCHMARK_WRAPPER"), "exec", "-T", service, "ruby", "-rjson", "-e", "puts ENV.slice(*ARGV).to_json", *CONFIG_KEYS)
      raise "Cannot inspect #{service}: #{output}" unless status.success?
      [service, JSON.parse(output)]
    end
  end

  def verify_configuration!(item, configurations)
    configurations.each do |service, config|
      { "RAILS_ENV" => @stack_env.fetch("RAILS_ENV"), "IAM_DEMO_BATCH_SIZE" => item.fetch("batch_size").to_s, "AUTHORIZATION_CHECK_MODE" => item.fetch("auth") }.each do |key, expected|
        raise "#{service}: #{key} mismatch" unless config[key] == expected
      end
      if %w[account-service account-auth-service authorization-service organization-service organization-auth-service].include?(service)
        raise "#{service}: Redis mismatch" unless config["GLOBAL_IAM_DEMO_USE_REDIS"] == item.fetch("redis")
      end
    end
    raise "Retrieval mode mismatch" unless configurations.fetch("user-management-service")["IAM_DEMO_RETRIEVAL_MODE"] == item.fetch("retrieval")
  end

  def write_json(path, data)
    File.write(path + ".tmp", JSON.pretty_generate(data) + "\n")
    File.rename(path + ".tmp", path)
  end
end

ArticleCollection.new.run if $PROGRAM_NAME == __FILE__
