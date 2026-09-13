require "minitest/autorun"
require_relative "../scripts/refresh_article_traces"

class ArticleTraceRefreshTest < Minitest::Test
  class Probe < ArticleTraceRefresh
    attr_reader :operations
    def initialize
      @operations = []
      @directory = "/tmp/fake-collection"
      @env = {}
      @stack_env = { "BENCHMARK_WRAPPER" => "./dc_prod" }
      @warm_processes = { "service" => [[18, "100"]] }
    end
    def write_json(*) = nil
    def command(_env, _log, *args) = @operations << [:command, args]
    def organization_request(*) = ["GET", "http://example/partition", nil]
    def request(id, *args, **options)
      @operations << [:request, id, options]
      { "outcome" => "ok" }
    end
    def rails_processes = @processes || @warm_processes
    def change_process! = @processes = { "service" => [[19, "200"]] }
  end

  def test_rails_warmups_precede_redis_only_cold_flush_and_no_restart_separates_samples
    probe = Probe.new
    capture_io { probe.send(:warm_case, { "id" => "cache-wide-can", "fixture" => "wide_org", "redis" => "true" }) }
    probe.send(:cold_warm, "organization", ["GET", "http://example/partition", nil])
    requests = probe.operations.select { |op| op.first == :request }
    assert_equal %w[warmup-1 warmup-2 organization-cold organization-prime organization-warm], requests.map { |op| op[1] }
    assert requests.first(2).all? { |op| op[2] == { archive: false, warmup: true } }
    commands = probe.operations.select { |op| op.first == :command }.map(&:last)
    assert_equal 8, commands.size
    assert commands.all? { |cmd| cmd.first == "./dc_prod" && cmd.last(4) == ["redis-cli", "-n", "1", "FLUSHDB"] }
    second_warm = probe.operations.index(requests[1])
    cold = probe.operations.index(requests[2])
    assert_equal 4, probe.operations[(second_warm + 1)...cold].size
    assert probe.operations[(cold + 1)..].none? { |op| op.first == :command }
  end

  def test_a_restarted_rails_process_cannot_be_labeled_warmed
    probe = Probe.new
    probe.send(:verify_warm_processes!, "stable")
    probe.change_process!
    assert_raises(RuntimeError) { probe.send(:verify_warm_processes!, "changed") }
  end
end
