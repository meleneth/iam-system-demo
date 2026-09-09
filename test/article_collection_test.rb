require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/collect_article_evidence"

class ArticleCollectionTest < Minitest::Test
  class FakeCollection < ArticleCollection
    attr_reader :executed, :commands
    def initialize(out, fail_smoke: false, revision: "test")
      @commands = []
      @stack_env = BenchmarkEnvironment.values
      @out = out
      @manifest = File.join(out, "input.json")
      File.write(@manifest, "{}")
      matrix = JSON.parse(File.read("benchmarks/article_matrix.json"))
      @matrix = matrix.merge("cases" => matrix.fetch("cases").select { |item| %w[smoke-hierarchies smoke-organization auth-wide-can].include?(item.fetch("id")) })
      @fingerprint = { "revision" => revision }
      @revision, @fail_smoke, @executed = revision, fail_smoke, []
    end

    private

    def capture(*) = ""
    def command(_env, log, *args)
      @commands << args
      File.write(log, "fake setup\n")
    end
    def wait_for_apps(*) = nil
    def runtime_configuration(env) = APPS.to_h { |service| [service, env] }
    def run_driver(env, _driver, log)
      @executed << env.fetch("OUT_DIR")
      File.write(log, "fake driver\n")
      @fail_smoke ? [false, 1] : [true, 0]
    end
  end

  def setup
    @old_case_ids = ENV.delete("CASE_IDS")
    @old_retry = ENV.delete("RETRY_FAILED")
    @dir = Dir.mktmpdir("article-collection-test")
  end

  def teardown
    ENV["CASE_IDS"], ENV["RETRY_FAILED"] = @old_case_ids, @old_retry
    FileUtils.remove_entry(@dir)
  end

  def test_resumes_completed_cases_without_rerunning_them
    first = FakeCollection.new(@dir)
    capture_io { first.run }
    assert_equal 3, first.executed.size
    assert_includes first.commands, ["./analyze_databases.sh", "prod"]
    assert first.commands.select { |args| args.include?("up") }.all? { |args| args.first == "./dc_prod" }
    second = FakeCollection.new(@dir)
    capture_io { second.run }
    assert_empty second.executed
    assert_equal 3, JSON.parse(File.read(File.join(@dir, "collection_status.json"))).fetch("completed_cases")
  end

  def test_smoke_failure_blocks_measurements_and_retry_preserves_previous_attempt
    first = FakeCollection.new(@dir, fail_smoke: true)
    capture_io { assert_raises(RuntimeError) { first.run } }
    assert_equal 1, first.executed.size
    refute File.exist?(File.join(@dir, "smoke-hierarchies", "completed.json"))
    second = FakeCollection.new(@dir)
    capture_io { second.run }
    assert File.exist?(File.join(@dir, "smoke-hierarchies", "attempt-001", "status.json"))
    assert File.exist?(File.join(@dir, "smoke-hierarchies", "attempt-002", "status.json"))
  end

  def test_selected_measurements_cannot_bypass_smoke_gates
    ENV["CASE_IDS"] = "auth-wide-can"
    collection = FakeCollection.new(@dir)
    capture_io { assert_raises(RuntimeError) { collection.run } }
    assert_empty collection.executed
  end

  def test_changed_revision_cannot_resume_same_collection
    capture_io { FakeCollection.new(@dir).run }
    assert_raises(RuntimeError) { FakeCollection.new(@dir, revision: "different").run }
  end
end
