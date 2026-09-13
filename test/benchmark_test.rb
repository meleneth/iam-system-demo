require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "csv"
require "open3"

class BenchmarkTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @dir = Dir.mktmpdir("iam-benchmark-test")
    FileUtils.cp(File.join(ROOT, "benchmark_demo.sh"), @dir)
    FileUtils.cp_r(File.join(ROOT, "scripts"), @dir)
    # This harness test stubs the external correctness executable, not an IAM
    # decision. The real gate is exercised by cross-service RSpec before timing.
    File.write(File.join(@dir, "scripts/authorization_correctness_gate.rb"), "exit(ENV['FAKE_CORRECTNESS_FAILURE'] == '1' ? 1 : 0)\n")
    FileUtils.mkdir_p(File.join(@dir, "bin"))
    fixtures = %w[deep_chain wide_org dense_account branching_tree massive_fanout_100k massive_fanout_50k massive_fanout_10k].map do |name|
      { name: name, organization_id: "org", targets: { leaf_account_id: "leaf", root_account_id: "root", account_id: "account", msp_account_id: "msp", admin_user_id: "actor" } }
    end
    File.write(File.join(@dir, "manifest.json"), JSON.generate(fixtures: fixtures))
    File.write(File.join(@dir, "dc_prod"), <<~'STUB')
      #!/bin/sh
      [ "$5" = "-n" ] && [ "$6" = "1" ] || exit 2
      echo flush >> events.log
    STUB
    FileUtils.chmod(0755, File.join(@dir, "dc_prod"))
    File.write(File.join(@dir, "bin/curl"), <<~'STUB')
      #!/usr/bin/env ruby
      require "json"
      output = ARGV[ARGV.index("-o") + 1]
      url = ARGV.last
      traceparent = ARGV.find { |arg| arg.start_with?("traceparent:") }
      raise "No sampled traceparent" unless traceparent&.match?(/traceparent: 00-[0-9a-f]{32}-[0-9a-f]{16}-01/)
      File.open("traceheaders.log", "a") { |f| f.puts(traceparent) }
      page = url.include?("continuance=") ? 2 : 1
      File.open("events.log", "a") { |f| f.puts("page#{page}") }
      if ENV["FAKE_TIMEOUT"] == "1"
        File.write(output, "partial response")
        print "000,2.500,16"
        exit 28
      end
      payload = { accounts: [{ id: "a#{page}" }], users: [], partition_account_count: 1,
        total_account_count: 2, retrieval_mode: "batched", batch_size: 1 }
      body = %(<script type="application/json">#{JSON.generate(payload)}</script>)
      body += %(<turbo-frame src="/organization_user_management/partition?continuance=next&amp;organization_id=org"></turbo-frame>) if page == 1
      File.write(output, body)
      print "200,0.125,#{body.bytesize}"
    STUB
    FileUtils.chmod(0755, File.join(@dir, "bin/curl"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_benchmark(extra = {})
    env = { "PATH" => "#{@dir}/bin:#{ENV.fetch('PATH')}", "MANIFEST" => "manifest.json", "OUT_DIR" => "out",
      "RUNS" => "2", "FOCUSED_ORGANIZATION_ONLY" => "1", "GRAFANA_ANNOTATIONS_ENABLED" => "0",
      "GLOBAL_IAM_DEMO_USE_REDIS" => "true", "CACHE_WAIT_SECONDS" => "0", "ARCHIVE_TRACES" => "0",
      "IAM_DEMO_BATCH_SIZE" => "1" }
    @output, @status = Open3.capture2e(env.merge(extra), "bash", "benchmark_demo.sh", chdir: @dir)
    CSV.read(File.join(@dir, "out/timings.csv"), headers: true)
  end

  def test_flushes_every_cold_sample_but_never_between_pages_and_primes_every_warm_sample
    rows = run_benchmark
    assert @status.success?, @output
    events = File.readlines(File.join(@dir, "events.log"), chomp: true)
    assert_equal((%w[flush flush flush flush page1 page2] * 2) + (%w[page1 page2 page1 page2] * 2), events)
    walks = rows.select { |row| row["label"].end_with?("full_walk") }
    assert_equal 6, walks.size # two cold, two warm primes, two warm measurements
    assert walks.all? { |row| row["notes"].include?("outcome=ok pages=2 accounts=2") }
  end

  def test_exports_each_page_under_its_initiated_trace_id_and_fails_on_export_errors
    File.write(File.join(@dir, "scripts/archive_trace.rb"), <<~'STUB')
      require "json"
      base, trace_id, parent_id, output = ARGV
      File.write(output, JSON.generate(data: [{ traceID: trace_id }]))
      exit(ENV["FAKE_EXPORT_FAILURE"] == "1" ? 1 : 0)
    STUB
    rows = run_benchmark("ARCHIVE_TRACES" => "1", "COLD_ONLY" => "1", "RUNS" => "1", "FAKE_EXPORT_FAILURE" => "1")
    refute @status.success?
    samples = rows.reject { |row| row["label"].end_with?("full_walk") }
    assert_equal 2, samples.size
    headers = File.readlines(File.join(@dir, "traceheaders.log"))
    samples.each_with_index do |sample, index|
      summary = JSON.parse(File.read(File.join(@dir, "#{sample['response_file']}.result.json")))
      archived = JSON.parse(File.read(File.join(@dir, summary.fetch("trace_file"))))
      assert_equal summary.fetch("trace_id"), archived.fetch("data").first.fetch("traceID")
      assert_includes headers[index], summary.fetch("trace_id")
    end
  end

  def test_rejects_running_partition_settings_that_differ_from_metadata
    rows = run_benchmark("IAM_DEMO_BATCH_SIZE" => "2", "COLD_ONLY" => "1", "RUNS" => "1")
    refute @status.success?
    sample = rows.find { |row| row["label"].end_with?("page_1") }
    assert_includes sample["notes"], "outcome=configuration_mismatch"
  end

  def test_keeps_timeout_duration_and_body_and_exits_unsuccessfully
    rows = run_benchmark("FAKE_TIMEOUT" => "1", "COLD_ONLY" => "1", "RUNS" => "1")
    refute @status.success?
    sample = rows.find { |row| row["label"].end_with?("page_1") }
    assert_equal "2.500", sample["time_total"]
    assert_includes sample["notes"], "outcome=timeout"
    assert_equal "partial response", File.read(File.join(@dir, sample["response_file"]))
  end
  def test_failed_correctness_gate_prevents_cache_flushes_and_measurement
    assert_raises(Errno::ENOENT) { run_benchmark("FAKE_CORRECTNESS_FAILURE" => "1") }
    refute @status.success?
    refute File.exist?(File.join(@dir, "events.log"))
    refute File.exist?(File.join(@dir, "out/timings.csv"))
  end

end
