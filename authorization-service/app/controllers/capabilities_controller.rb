# frozen_string_literal: true

class CapabilitiesController < ApplicationController
  def organization
    render json: capability_service.for_organization(params.require(:organization_id))
  end

  def account
    render json: capability_service.for_account(params.require(:account_id))
  end

  def organizations
    render json: capability_map { |scope_id| capability_service.for_organization(scope_id) }
  end

  def accounts
    render json: capability_map { |scope_id| capability_service.for_account(scope_id) }
  end

  private

  def capability_service
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise ActionController::BadRequest, "pad-user-id header required" if user_id.blank?

    Authorization::Capabilities.new(user_id: user_id)
  end

  def capability_map
    scope_ids = Array(params.permit(scope_id: [])[:scope_id]).map(&:to_s).uniq
    raise ActionController::BadRequest, "scope_id must be an array" if scope_ids.empty?

    scope_ids.to_h { |scope_id| [scope_id, yield(scope_id)] }
  end
end
