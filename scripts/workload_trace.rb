# frozen_string_literal: true

require 'json'
require 'net/http'

# Record the real client-side workload interval as the parent already carried
# in traceparent. Export happens after the request, outside its measured interval.
class WorkloadTrace
  def initialize(endpoint:, name:, attributes:, sender: nil)
    @endpoint, @name, @attributes = endpoint, name, attributes
    @sender = sender || method(:send_payload)
    @started_at = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    @started_tick = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end

  def stop
    @ended_at ||= @started_at + Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - @started_tick
  end

  def export(trace_id:, span_id:, outcome:)
    stop
    attributes = @attributes.merge('workload.outcome' => outcome)
    span = {
      traceId: trace_id, spanId: span_id, name: @name, kind: 1,
      startTimeUnixNano: @started_at.to_s, endTimeUnixNano: @ended_at.to_s,
      attributes: attributes.map { |key, value| {key: key, value: otlp_value(value)} },
      status: outcome == 'ok' ? {code: 1} : {code: 2, message: outcome}
    }
    payload = {resourceSpans: [{
      resource: {attributes: [{key: 'service.name', value: {stringValue: 'trace-workloads'}}]},
      scopeSpans: [{scope: {name: 'iam.workload'}, spans: [span]}]
    }]}
    @sender.call(payload)
    @name
  end

  private

  def otlp_value(value)
    case value
    when Integer then {intValue: value.to_s}
    when true, false then {boolValue: value}
    else {stringValue: value.to_s}
    end
  end

  def send_payload(payload)
    uri = URI(@endpoint.delete_suffix('/') + '/v1/traces')
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 15) do |http|
      http.post(uri.request_uri, JSON.generate(payload), 'Content-Type' => 'application/json')
    end
    raise "Workload trace export HTTP #{response.code}: #{response.body}" unless response.code == '200'
    result = response.body.empty? ? {} : JSON.parse(response.body)
    raise "Workload trace rejected: #{result}" if result.dig('partialSuccess', 'rejectedSpans').to_i.positive?
  end
end
