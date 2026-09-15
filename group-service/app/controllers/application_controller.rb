require_relative '../../lib/request_operation_tracing'

class ApplicationController < ActionController::API
  include RequestOperationTracing
  class AuthorizationDenied < StandardError; end

  rescue_from AuthorizationDenied do
    render json: { error: "forbidden" }, status: :forbidden
  end
end
