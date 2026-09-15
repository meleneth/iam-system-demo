require 'minitest/autorun'
require 'net/http'
require 'json'
require 'rack/mock'
require 'action_controller'
require 'puma'
require 'puma/server'
require 'opentelemetry/sdk'
require 'opentelemetry/instrumentation/net/http'
require 'opentelemetry/instrumentation/rack'
require_relative '../../user-service/lib/request_operation_tracing'

class UsersController < ActionController::API
  include RequestOperationTracing

  def search
    return render json: {error: 'forbidden'}, status: :forbidden if params[:deny]
    # Return fewer records than requested to prove labels use the result count.
    rows = Array(params[:ids]).first(2).map { |id| {id: id} }
    render json: rows
  end
end

class RequestNamesTest < Minitest::Test
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |c|
    c.use 'OpenTelemetry::Instrumentation::Net::HTTP'
    c.use 'OpenTelemetry::Instrumentation::Rack', {use_rack_events: false}
    c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER))
  end
  require_relative '../../user-service/lib/http_request_tracing'

  def test_client_and_server_names_use_returned_counts_without_changing_http_metadata
    app = OpenTelemetry::Instrumentation::Rack::Middlewares::TracerMiddleware.new(UsersController.action(:search))
    server = Puma::Server.new(app, Puma::Events.new, min_threads: 1, max_threads: 1)
    server.add_tcp_listener('127.0.0.1', 0)
    server.run
    uri = URI("http://127.0.0.1:#{server.binder.ios.first.addr[1]}/users/search")
    [[[], 'Load 0 users'], [[1], 'Load 1 user'], [[1, 2, 3], 'Load 2 users']].each do |ids, expected|
      EXPORTER.reset
      response = Net::HTTP.post(uri, JSON.generate(ids: ids), {'Content-Type' => 'application/json'})
      assert_equal '200', response.code
      assert_equal ids.first(2), JSON.parse(response.body).map { |row| row.fetch('id') }
      spans = EXPORTER.finished_spans.select { |span| [:client, :server].include?(span.kind) }
      assert_equal 2, spans.size
      assert spans.all? { |span| span.name == expected }, spans.map(&:name).inspect
      assert spans.all? { |span| span.attributes['http.method'] == 'POST' }
      client = spans.find { |span| span.kind == :client }
      assert_equal client.span_id, spans.find { |span| span.kind == :server }.parent_span_id
    end
    EXPORTER.reset
    response = Net::HTTP.post(uri, JSON.generate(ids: [1, 2], deny: true), {'Content-Type' => 'application/json'})
    assert_equal '403', response.code
    assert_nil response['X-IAM-Trace-Operation']
    refute EXPORTER.finished_spans.any? { |span| span.name.start_with?('Load ') }
  ensure
    server&.stop(true)
  end

  def test_service_copies_stay_in_sync
    root = File.expand_path('../..', __dir__)
    %w[request_operation_tracing.rb http_request_tracing.rb].each do |file|
      copies = Dir[File.join(root, '*-service', 'lib', file)].map { |path| File.read(path) }
      assert_equal 6, copies.size
      assert_equal 1, copies.uniq.size
    end
  end
end
