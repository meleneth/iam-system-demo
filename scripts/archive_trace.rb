# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "set"

class TraceArchive
  def initialize(base_url:, timeout: 60, quiet_seconds: 5, poll_seconds: 1,
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) }, fetch: nil)
    @base_url = base_url.delete_suffix("/")
    @timeout, @quiet_seconds, @poll_seconds = timeout, quiet_seconds, poll_seconds
    raise ArgumentError, "Trace timeout/poll must be positive and quiet time nonnegative" unless timeout > 0 && poll_seconds > 0 && quiet_seconds >= 0
    @clock, @sleeper = clock, sleeper
    @fetch = fetch || method(:fetch_trace)
  end

  def archive(trace_id:, parent_id:, output:, require_root: false)
    deadline = @clock.call + @timeout
    stable_since = nil
    previous = nil
    latest = { "data" => [] }
    status = "missing"
    reason = "Trace has not reached Jaeger"
    loop do
      begin
        payload = @fetch.call(trace_id)
        trace = Array(payload && payload["data"]).find { |item| item.fetch("traceID").rjust(32, "0") == trace_id }
        if trace
          latest = payload
          spans = trace.fetch("spans")
          fingerprint = spans.map { |span| [span.fetch("spanID"), span.fetch("startTime"), span.fetch("duration")] }.sort
          if fingerprint != previous
            previous = fingerprint
            stable_since = @clock.call
          end
          complete = connected?(spans, trace_id, parent_id) && (!require_root || spans.any? { |span| span.fetch('spanID') == parent_id })
          status = "incomplete"
          reason = complete ? "Waiting for span count to settle" : "Root or referenced parent spans are missing"
          if complete && @clock.call - stable_since >= @quiet_seconds
            status, reason = "archived", nil
            break
          end
        end
      rescue StandardError => error
        reason = "#{error.class}: #{error.message}"
      end
      break if @clock.call >= deadline
      @sleeper.call([@poll_seconds, deadline - @clock.call].min.clamp(0, @poll_seconds))
    end

    File.write(output, JSON.pretty_generate(latest) + "\n")
    manifest = { trace_id: trace_id, initiating_span_id: parent_id, status: status,
      span_count: previous&.size || 0, fetched_at: Time.now.utc.iso8601,
      quiet_seconds: @quiet_seconds, error: reason }
    File.write(output.sub(/\.json\z/, ".status.json"), JSON.pretty_generate(manifest) + "\n")
    manifest
  end

  private

  def connected?(spans, trace_id, parent_id)
    ids = spans.map { |span| span.fetch("spanID") }.to_set
    references = spans.flat_map { |span| Array(span["references"]) }
      .select { |ref| ref["refType"] == "CHILD_OF" && ref.fetch("traceID").rjust(32, "0") == trace_id }
    references.any? { |ref| ref["spanID"] == parent_id } &&
      references.all? { |ref| ref["spanID"] == parent_id || ids.include?(ref["spanID"]) }
  end

  def fetch_trace(trace_id)
    uri = URI("#{@base_url}/api/traces/#{trace_id}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
      http.get(uri.request_uri)
    end
    return nil if response.code == "404"
    raise "Jaeger HTTP #{response.code}" unless response.code == "200"
    JSON.parse(response.body)
  end
end

if $PROGRAM_NAME == __FILE__
  base_url, trace_id, parent_id, output = ARGV
  result = TraceArchive.new(base_url: base_url,
    timeout: Float(ENV.fetch("TRACE_EXPORT_TIMEOUT_SECONDS", "60")),
    quiet_seconds: Float(ENV.fetch("TRACE_QUIET_SECONDS", "5"))).archive(
      trace_id: trace_id, parent_id: parent_id, output: output)
  warn "Trace #{trace_id}: #{result.fetch(:status)} (#{result.fetch(:span_count)} spans) -> #{output}"
  exit(result.fetch(:status) == "archived" ? 0 : 1)
end
