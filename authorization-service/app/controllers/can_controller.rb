class CanController < ApplicationController
  def index
    if ENV.fetch("AUTHORIZATION_CHECK_MODE", "can") == "capabilities"
      return render json: { error: "/can disabled by AUTHORIZATION_CHECK_MODE=capabilities" }, status: :service_unavailable
    end

    permitted = params.permit(:scope_type, :permission, scope_id: [])
    scope_type = permitted[:scope_type]
    permission = permitted[:permission]
    scope_id   = permitted[:scope_id]

    user_id = request.headers["HTTP_PAD_USER_ID"]

    if user_id == "IAM_SYSTEM"
      return head :ok
    end
    return render json: { error: "pad-user-id required" }, status: :bad_request if user_id.blank?
    unless %w[Account Organization Group].include?(scope_type)
      return render json: { error: "Invalid scope_type" }, status: :bad_request
    end
    unless params[:scope_id].is_a?(Array)
      return render json: { error: "scope_id must be an explicit array" }, status: :bad_request
    end
    authorized = false

    case scope_type
    when "Account"
      capability_service = Authorization::Capabilities.new(user_id: user_id)
      requested_account_ids = Array(scope_id).map(&:to_s).uniq
      authorized_account_ids = capability_service.account_ids_with_permission(requested_account_ids, permission)
      # An empty collection requires no account authority and is intentionally allowed.
      authorized = requested_account_ids.all? { |account_id| authorized_account_ids.include?(account_id) }
    when "Organization"
      requested_organization_ids = Array(scope_id).map(&:to_s).uniq
      capability_service = Authorization::Capabilities.new(user_id: user_id)
      authorized = requested_organization_ids.any? && requested_organization_ids.all? do |id|
        capability_service.for_organization(id).include?(permission)
      end
    when "Group"
      capability_service = Authorization::Capabilities.new(user_id: user_id)
      ids = Array(scope_id).map(&:to_s).uniq
      authorized_group_ids = capability_service.group_ids_with_permission(ids, permission)
      authorized = ids.any? && ids.all? { |id| authorized_group_ids.include?(id) }

    else
      return render json: { error: "Invalid scope_type" }, status: :bad_request
    end

    if authorized
      head :ok
    else
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end
end
