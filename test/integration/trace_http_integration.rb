# Exercise the actual Faraday/Net::HTTP instrumentation without Rails or a DB.
require "socket"
require "faraday"
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/faraday"
require "opentelemetry/instrumentation/net/http"

exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::Faraday", { enable_internal_instrumentation: true }
  c.use "OpenTelemetry::Instrumentation::Net::HTTP"
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
end
require_relative "../../account-service/lib/http_phases"
listener = TCPServer.new("127.0.0.1", 0)
received = nil
server = Thread.new do
  socket = listener.accept
  headers = +""
  headers << socket.gets until headers.end_with?("\r\n\r\n")
  body = socket.read(headers[/Content-Length: (\d+)/i, 1].to_i)
  received = [headers, body]
  socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
  socket.close
end
begin
  OpenTelemetry.tracer_provider.tracer("test").in_span("lookup") do
    response = Faraday.post("http://127.0.0.1:#{listener.addr[1]}/organization_account_ids/for_account_ids") do |req|
      req.headers["pad-user-id"] = "real-actor"
      req.body = '{"account_ids":["a"]}'
    end
    raise "response changed" unless response.status == 200 && response.body == "{}"
  end
  server.value
  spans = exporter.finished_spans
  client = spans.find { |s| s.name == "HTTP POST" && s.instrumentation_scope.name.include?("Faraday") }
  raise "missing existing Faraday span" unless client
  traceparent = received.first[/^Traceparent: (.+)\r$/i, 1]
  propagated_id = traceparent&.split("-")&.at(2)
  propagated = spans.find { |s| s.span_id.unpack1("H*") == propagated_id }
  raise "propagated unknown parent" unless propagated
  raise "actor changed" unless received.first.match?(/^Pad-User-Id: real-actor\r$/i)
  raise "body changed" unless received.last == '{"account_ids":["a"]}'
  %w[http.connection.connect http.request.write http.response.headers.wait_and_read http.response.body.read].each do |name|
    phase = spans.find { |s| s.name == name }
    raise "missing phase #{name}" unless phase
    parent = spans.find { |s| s.span_id == phase.parent_span_id }
    while parent && parent.span_id != client.span_id
      parent = spans.find { |s| s.span_id == parent.parent_span_id }
    end
    raise "phase outside client: #{name}" unless parent
  end
  puts "Installed Faraday/Net::HTTP integration: phases nested, traceparent and actor preserved"
ensure
  listener.close
  server.kill if server.alive?
end
