# frozen_string_literal: true

module Internal
  class MspManagedOrganizationsController < ApplicationController
    DEFAULT_LIMIT = 1_000
    MAX_LIMIT = 1_000

    before_action :require_internal_system!

    def show
      msp_account_id = params.require(:msp_account_id)
      offset = params.fetch(:continuance, 0).to_i
      limit = params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)

      relationship = MspManagedOrganization.find_by(msp_account_id: msp_account_id)
      return render json: empty_page(msp_account_id) unless relationship

      account_scope = managed_account_scope(msp_account_id)
      total_count = account_scope.count
      account_ids = account_scope.offset(offset).limit(limit).pluck(:account_id).map(&:to_s)
      next_offset = offset + account_ids.length

      render json: {
        msp_organization_id: relationship.msp_organization_id,
        msp_account_id: msp_account_id,
        managed_account_ids: account_ids,
        total_count: total_count,
        continuance: next_offset < total_count ? next_offset.to_s : nil
      }
    end

    private

    def require_internal_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
    end

    def managed_account_scope(msp_account_id)
      OrganizationAccount
        .joins("INNER JOIN msp_managed_organizations ON msp_managed_organizations.client_organization_id = organization_accounts.organization_id")
        .where(msp_managed_organizations: { msp_account_id: msp_account_id })
        .order(:account_id)
    end

    def empty_page(msp_account_id)
      {
        msp_organization_id: nil,
        msp_account_id: msp_account_id,
        managed_account_ids: [],
        total_count: 0,
        continuance: nil
      }
    end
  end
end
