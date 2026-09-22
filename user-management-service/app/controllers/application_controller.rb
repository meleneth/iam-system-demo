require_relative '../../lib/request_operation_tracing'

class ApplicationController < ActionController::Base
  include RequestOperationTracing
  rescue_from ActiveResource::ForbiddenAccess, AuthorizedResource::AuthorizationDenied do
    render plain: "Forbidden", status: :forbidden
  end
  rescue_from ActiveResource::ResourceNotFound do
    head :not_found
  end
  rescue_from AuthorizationContext::MissingContextError do |error|
    render plain: error.message, status: :forbidden
  end
  rescue_from AuthorizationContext::InvalidContextError, AuthorizationContext::UnauthenticatedAuthorityError do |error|
    render plain: error.message, status: :forbidden
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
