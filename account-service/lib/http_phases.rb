# frozen_string_literal: true

require "net/http"

# Boundaries of net-http 0.6, used by Faraday::Adapter::NetHttp. These
# measure Ruby operations, not wire arrival, DNS alone, or server queue time.
module HttpPhases
  def self.trace(name, attributes = {})
    return yield(nil) unless ENV.fetch("IAM_TRACE_HTTP_PHASES", "true") == "true" &&
      OpenTelemetry::Trace.current_span.recording?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    OpenTelemetry.tracer_provider.tracer("iam.http_phases").in_span(name, attributes: attributes) do |span|
      begin
        yield(span)
      ensure
        span.set_attribute("phase.elapsed_ms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      end
    end
  end

  module Connection
    private

    def connect(...)
      HttpPhases.trace("http.connection.connect", "server.address" => address, "server.port" => port) { super }
    end

    def begin_transport(...)
      previous_socket = @socket
      previously_used = !@last_communicated.nil?
      HttpPhases.trace("http.connection.prepare", "server.address" => address, "server.port" => port) do |span|
        result = super
        span&.set_attribute("http.connection.reused", previously_used && previous_socket.equal?(@socket))
        if span && @socket&.io.respond_to?(:peeraddr)
          begin
            peer = @socket.io.peeraddr(false)
            span.set_attribute("network.peer.address", peer[3])
            span.set_attribute("network.peer.port", peer[1])
          rescue IOError, SystemCallError
            # Peer metadata is optional if the socket closed in the meantime.
          end
        end
        result
      end
    end
  end

  module Request
    def exec(...)
      attributes = body.is_a?(String) ? { "http.request.body.size" => body.bytesize } : {}
      HttpPhases.trace("http.request.write", attributes) { super }
    end
  end

  module Headers
    def read_new(...)
      HttpPhases.trace("http.response.headers.wait_and_read") { super }
    end
  end

  module Body
    def read_body(...)
      # Net::HTTP may ask for an already buffered body more than once.
      return super if @read

      HttpPhases.trace("http.response.body.read") do |span|
        result = super
        span&.set_attribute("http.response.body.size", @body.bytesize) if @body.is_a?(String)
        result
      end
    end
  end
end

Net::HTTP.prepend(HttpPhases::Connection)
Net::HTTPGenericRequest.prepend(HttpPhases::Request)
Net::HTTPResponse.singleton_class.prepend(HttpPhases::Headers)
Net::HTTPResponse.prepend(HttpPhases::Body)
