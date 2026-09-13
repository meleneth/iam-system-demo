class ApplicationController < ActionController::Base
  rescue_from ActiveResource::ForbiddenAccess do
    render plain: "Forbidden", status: :forbidden
  end
  rescue_from ActiveResource::ResourceNotFound do
    head :not_found
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
end
