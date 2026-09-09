require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/benchmark_hierarchies"

class HierarchyComparisonTest < Minitest::Test
  def setup
    @accounts = [ { "id" => "a", "parent_account_id" => nil }, { "id" => "b", "parent_account_id" => "a" }, { "id" => "c", "parent_account_id" => "b" } ]
    @fixture = { "accounts" => @accounts }
    @calls = []
    @request = lambda do |method, path, body, headers, _timeout|
      @calls << [method, path, body, headers]
      result = if path == "/accounts_with_parents"
        body.fetch(:account_ids).reverse.map { |id| HierarchyComparison.expected_chain(@fixture, id) }
      elsif path.start_with?("/account_with_parents/")
        HierarchyComparison.expected_chain(@fixture, path.split("/").last)
      else
        @accounts.find { |row| row.fetch("id") == path.split("/").last }
      end
      [200, JSON.generate(result)]
    end
  end

  def measure(mode, ids, request = @request)
    runner = HierarchyComparison.new(base_url: "http://unused", actor: "real-actor", batch_size: 2, timeout: 10, request: request)
    expected = ids.to_h { |id| [id, HierarchyComparison.expected_chain(@fixture, id)] }
    Dir.mktmpdir { |dir| runner.measure(mode: mode, target_ids: ids, expected: expected, directory: dir) }
  end

  def test_parent_walk_and_cte_return_equivalent_hierarchies_as_the_same_real_actor
    walk = measure("walk", ["c"])
    cte = measure("cte", ["c"])
    assert_equal "ok", walk.fetch(:outcome)
    assert_equal "ok", cte.fetch(:outcome)
    assert_equal walk.fetch(:result_sha256), cte.fetch(:result_sha256)
    assert_equal 3, walk.fetch(:request_count)
    assert_equal 1, cte.fetch(:request_count)
    assert @calls.all? { |call| call.last.fetch("pad-user-id") == "real-actor" }
    assert @calls.all? { |call| call.last.fetch("traceparent").match?(/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/) }
  end

  def test_individual_and_chunked_batches_are_equivalent_despite_reordered_responses
    individual = measure("individual", %w[c b a])
    batch = measure("batch", %w[c b a])
    assert_equal "ok", batch.fetch(:outcome)
    assert_equal individual.fetch(:result_sha256), batch.fetch(:result_sha256)
    assert_equal 3, individual.fetch(:request_count)
    assert_equal 2, batch.fetch(:request_count)
  end

  def test_denial_is_not_retried_as_a_system_actor
    result = measure("walk", ["c"], ->(*) { [403, '{"error":"forbidden"}'] })
    assert_equal "http_error", result.fetch(:outcome)
    assert_equal 1, result.fetch(:request_count)
  end

  def test_wrong_hierarchy_is_a_failed_sample
    result = measure("cte", ["c"], ->(*) { [200, JSON.generate([@accounts.last])] })
    assert_equal "inequivalent_result", result.fetch(:outcome)
  end

  def test_requires_real_actor
    assert_raises(ArgumentError) { HierarchyComparison.new(base_url: "http://unused", actor: "IAM_SYSTEM", batch_size: 2, timeout: 10) }
  end
end
