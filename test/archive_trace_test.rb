require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/archive_trace"

class ArchiveTraceTest < Minitest::Test
  TRACE = "1" * 32
  PARENT = "2" * 16

  def span(id, parent)
    { "spanID" => id, "startTime" => 1000, "duration" => 50,
      "references" => [{ "refType" => "CHILD_OF", "traceID" => TRACE, "spanID" => parent }] }
  end

  def payload(spans)
    { "data" => [{ "traceID" => TRACE, "spans" => spans, "processes" => {} }] }
  end

  def archive(fetch, quiet: 2, timeout: 6)
    now = 0.0
    Dir.mktmpdir do |dir|
      output = File.join(dir, "trace.json")
      result = TraceArchive.new(base_url: "http://unused", quiet_seconds: quiet, timeout: timeout,
        fetch: fetch, clock: -> { now }, sleeper: ->(seconds) { now += seconds }).archive(trace_id: TRACE, parent_id: PARENT, output: output)
      yield result, JSON.parse(File.read(output)), JSON.parse(File.read(File.join(dir, "trace.status.json")))
    end
  end

  def test_waits_for_delayed_and_growing_trace_then_preserves_jaeger_json
    root = span("root", PARENT)
    child = span("child", "root")
    responses = [nil, payload([root]), payload([root, child])]
    final = responses.last
    calls = 0
    archive(->(_id) { calls += 1; responses.shift || final }) do |result, json, status|
      assert_equal "archived", result.fetch(:status)
      assert_operator calls, :>=, 5
      assert_equal final, json
      assert_equal 2, status.fetch("span_count")
    end
  end

  def test_preserves_partial_trace_and_marks_missing_parent_incomplete
    partial = payload([span("child", "missing-root")])
    archive(->(_) { partial }) do |result, json, _status|
      assert_equal "incomplete", result.fetch(:status)
      assert_equal partial, json
    end
  end

  def test_missing_trace_and_backend_errors_are_explicit_failures
    archive(->(_) { raise IOError, "backend unavailable" }) do |result, json, status|
      assert_equal "missing", result.fetch(:status)
      assert_equal [], json.fetch("data")
      assert_includes status.fetch("error"), "backend unavailable"
    end
  end
end
