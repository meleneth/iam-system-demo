# frozen_string_literal: true

module Internal
  class AdminUsersController < ApplicationController
    ORG_ADMIN_PERMISSION = "organization.accounts.create"

    def organization
      return unless require_iam_system!

      organization_id = params.require(:organization_id)
      group_ids = CapabilityGrant.where(
        scope_type: "Organization", scope_id: organization_id, permission: ORG_ADMIN_PERMISSION
      ).distinct.pluck(:group_id)
      user_id = Authorization::GroupContextClient.new.user_ids_for(group_ids).first
      return render json: { error: "No organization admin found" }, status: :not_found unless user_id

      render json: { user_id: user_id, organization_id: organization_id, permission: ORG_ADMIN_PERMISSION }

    end

    private

    def require_iam_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
      false
    end
  end
end
