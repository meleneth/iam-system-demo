# frozen_string_literal: true

require "puma"
require "puma/server"
require "opentelemetry/sdk"

# Puma 6.6 request lifecycle hooks. Record clocks before trace context is
# available, then attach the observations to a request span after parsing.
# A socket read attempt is not a measurement of the packet's arrival time.
module ServerPhases
  def self.enabled?
    ENV.fetch("IAM_TRACE_SERVER_PHASES", "true") == "true"
  end

  def self.mark(client, name)
    return unless enabled?
    events = client.instance_variable_get(:@iam_server_events) || client.instance_variable_set(:@iam_server_events, [])
    events << [name, Time.now, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
  end

  module Client
    def initialize(...)
      super
      ServerPhases.mark(self, "puma.connection.accepted")
    end

    def reset(...)
      @iam_server_events = nil
      @iam_read_attempted = false
      super
    end

    def try_to_finish(...)
      unless @iam_read_attempted
        ServerPhases.mark(self, "puma.request.read.begin")
        @iam_read_attempted = true
      end
      super
    end

    def setup_body(...)
      ServerPhases.mark(self, "puma.request.headers.parsed")
      super
    end

    def set_ready(...)
      result = super
      ServerPhases.mark(self, "puma.request.body.ready")
      result
    end
  end

  module ThreadPool
    def <<(work)
      ServerPhases.mark(work, "puma.queue.enqueue") if work.is_a?(Puma::Client)
      super
    end
  end

  module Server
    def prepare_response(status, headers, body, requests, client)
      return super unless ServerPhases.enabled?

      if (span = client.env["iam.puma.span"])
        span.set_attribute("http.response.status_code", status.to_i)
        span.status = OpenTelemetry::Trace::Status.error if status.to_i >= 500
      end
      # Body enumeration can close/detach Rack's context. Do not attach a
      # temporary context around it; that would violate Rack's detach order.
      phase = OpenTelemetry.tracer_provider.tracer("iam.server_phases").start_span("puma.response.prepare_and_write",
        with_parent: OpenTelemetry::Trace.context_with_span(span || OpenTelemetry::Trace.current_span))
      begin
        super
      rescue Exception => error
        phase.record_exception(error)
        phase.status = OpenTelemetry::Trace::Status.error(error.class.name)
        raise
      ensure
        phase.finish
      end
    end

    def process_client(client)
      ServerPhases.mark(client, "puma.queue.dequeue")
      super
    end

    def handle_request(client, ...)
      return super unless ServerPhases.enabled?

      ServerPhases.mark(client, "puma.request.handle.begin")
      events = client.instance_variable_get(:@iam_server_events)
      parent = OpenTelemetry.propagation.extract(client.env,
        getter: OpenTelemetry::Common::Propagation.rack_env_getter)
      tracer = OpenTelemetry.tracer_provider.tracer("iam.server_phases")
      span = tracer.start_span("puma.request", with_parent: parent, start_timestamp: events.first[1], kind: :server,
        attributes: { "http.request.method" => client.env["REQUEST_METHOD"].to_s, "puma.version" => Puma::Const::PUMA_VERSION })
      client.env["iam.puma.span"] = span
      OpenTelemetry::Context.with_current(OpenTelemetry::Trace.context_with_span(span, parent_context: parent)) do
        # Rack extracts from the wire headers again; make it a child of the
        # Puma span, retaining the original remote parent on the Puma span.
        outgoing = {}
        OpenTelemetry.propagation.inject(outgoing)
        outgoing.each { |key, value| client.env["HTTP_#{key.upcase.tr('-', '_')}"] = value }
        events.each do |name, wall, mono|
          span.add_event(name, timestamp: wall, attributes: { "phase.elapsed_ms" => (mono - events.first[2]) * 1000 })
        end
        queued = nil
        events.each do |event|
          queued = event if event[0] == "puma.queue.enqueue"
          if event[0] == "puma.queue.dequeue" && queued
            phase = tracer.start_span("puma.queue.wait", start_timestamp: queued[1],
              attributes: { "phase.elapsed_ms" => (event[2] - queued[2]) * 1000 })
            phase.finish(end_timestamp: event[1])
            queued = nil
          end
        end
        span.set_attribute("puma.request_body_wait_ms", client.env["puma.request_body_wait"]) if client.env["puma.request_body_wait"]
        begin
          super
        rescue Exception => error # preserve Puma's exception behavior
          span.record_exception(error)
          span.status = OpenTelemetry::Trace::Status.error(error.class.name)
          raise
        ensure
          span.add_event("puma.request.handle.finish")
          span.set_attribute("phase.elapsed_ms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - events.first[2]) * 1000)
          span.finish
          client.env.delete("iam.puma.span")
        end
      end
    end
  end
end

if Gem::Version.new(Puma::Const::PUMA_VERSION).segments.first(2) == [6, 6]
  Puma::Client.prepend(ServerPhases::Client)
  Puma::ThreadPool.prepend(ServerPhases::ThreadPool)
  Puma::Server.prepend(ServerPhases::Server)
else
  warn "IAM server phase instrumentation supports Puma 6.6.x; hooks not installed"
end
