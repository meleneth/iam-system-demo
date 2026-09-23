require_relative '../../lib/request_operation_tracing'

class ApplicationController < ActionController::API
  include RequestOperationTracing
  around_action :establish_authorization_context

  rescue_from AuthorizationContext::MissingContextError do |error|
    render json: { error: error.message }, status: :forbidden
  end

  rescue_from AuthorizationContext::InvalidContextError do |error|
    render json: { error: error.message }, status: :forbidden
  end

  rescue_from AuthorizedResource::AuthorizationDenied do
    render json: { error: "forbidden" }, status: :forbidden
  end

  private

  def establish_authorization_context(&block)
    return AuthorizationContext.without(&block) if request.headers["HTTP_PAD_USER_ID"].blank? && request.headers["pad-user-id"].blank?
    AuthorizationContext.within_request(request.headers, &block)
  end
end
