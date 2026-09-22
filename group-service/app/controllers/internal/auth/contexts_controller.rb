# frozen_string_literal: true

module Internal
  module Auth
    class ContextsController < ApplicationController
      before_action :require_auth_system!

      def memberships
        memberships = GroupUser.authorized_internal_read("auth_memberships", identities: %w[IAM_SYSTEM_AUTH]) do
          rows = GroupUser.joins("INNER JOIN groups ON groups.id = group_users.group_id")
          if params[:user_id].present?
            rows = rows.where(user_id: params.require(:user_id))
          else
            ids = params.permit(group_ids: [])[:group_ids]
            raise ActionController::BadRequest, "group_ids must be an array" unless ids.is_a?(Array)
            rows = rows.where(group_id: ids)
          end
          rows.distinct.pluck(:group_id, :user_id)
        end
        render json: { memberships: memberships.map { |group_id, user_id| {group_id: group_id, user_id: user_id} } }
      end

      def groups
        ids = params.permit(group_ids: [])[:group_ids]
        raise ActionController::BadRequest, "group_ids must be an array" unless ids.is_a?(Array)
        groups = Group.authorized_internal_read("auth_group_contexts", identities: %w[IAM_SYSTEM_AUTH]) do
          Group.where(id: ids).pluck(:id, :account_id)
        end
        render json: { groups: groups.map { |id, account_id| {id: id, account_id: account_id} } }
      end

      private

      def require_auth_system!
        return if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM_AUTH"
        render json: {error: "IAM_SYSTEM_AUTH required"}, status: :forbidden
      end
    end
  end
end
