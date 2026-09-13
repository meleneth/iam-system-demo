class ApplicationController < ActionController::API
  class AuthorizationDenied < StandardError; end

  rescue_from AuthorizationDenied do
    render json: { error: "forbidden" }, status: :forbidden
  end
end
