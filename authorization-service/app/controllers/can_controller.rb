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
    authorized = false

    case scope_type
    when "Account"
      capability_service = Authorization::Capabilities.new(user_id: user_id)
      requested_account_ids = Array(scope_id).map(&:to_s).uniq
      authorized_account_ids = capability_service.account_ids_with_permission(requested_account_ids, permission)
      authorized = requested_account_ids.all? { |account_id| authorized_account_ids.include?(account_id) }
    when "Organization"
      # No hierarchy, just one org
      authorized = CapabilityGrant.exists?(
        user_id: user_id,
        permission: permission,
        scope_type: "Organization",
        scope_id: scope_id
      )
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
