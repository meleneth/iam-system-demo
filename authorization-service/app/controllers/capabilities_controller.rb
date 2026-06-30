# frozen_string_literal: true

class CapabilitiesController < ApplicationController
  def organization
    render json: capability_service.for_organization(params.require(:organization_id))
  end

  def account
    render json: capability_service.for_account(params.require(:account_id))
  end

  private

  def capability_service
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise ActionController::BadRequest, "pad-user-id header required" if user_id.blank?

    Authorization::Capabilities.new(user_id: user_id)
  end
end
