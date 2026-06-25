# frozen_string_literal: true

module Internal
  class AdminUsersController < ApplicationController
    ORG_ADMIN_PERMISSION = "organization.accounts.create"

    def organization
      return unless require_iam_system!

      organization_id = params.require(:organization_id)
      grant = CapabilityGrant
        .where(
          scope_type: "Organization",
          scope_id: organization_id,
          permission: ORG_ADMIN_PERMISSION
        )
        .order(:created_at, :user_id)
        .first

      return render json: { error: "No organization admin found" }, status: :not_found unless grant

      render json: {
        user_id: grant.user_id,
        organization_id: organization_id,
        permission: grant.permission
      }
    end

    private

    def require_iam_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
      false
    end
  end
end
