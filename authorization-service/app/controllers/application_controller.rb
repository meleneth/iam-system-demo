require_relative '../../lib/request_operation_tracing'

class ApplicationController < ActionController::API
  include RequestOperationTracing
end
