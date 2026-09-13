# frozen_string_literal: true

module Internal
  class MspManagedOrganizationsController < ApplicationController

    before_action :require_internal_system!, only: :show

    def show
      render_page
    end

    def authorized_show
      actor = request.headers["HTTP_PAD_USER_ID"]
      raise AuthorizationDenied if actor.blank? || actor == "IAM_SYSTEM_AUTH"
      render_page(actor: actor)
    end

    private

    def render_page(actor: nil)
      msp_account_id = params.require(:msp_account_id)
      offset = Integer(params.fetch(:continuance, 0), exception: false)
      raise ActionController::BadRequest, "invalid continuance" unless offset && offset >= 0
      limit = params.fetch(:limit, batch_size).to_i.clamp(1, batch_size)

      relationship = MspManagedOrganization.find_by(msp_account_id: msp_account_id)
      if actor && actor != "IAM_SYSTEM"
        raise AuthorizationDenied unless relationship &&
          OrganizationAccount.where(account_id: msp_account_id).distinct.pluck(:organization_id) == [relationship.msp_organization_id] &&
          User.user_can(actor, "Account", "account.read", msp_account_id)
      end
      return render json: empty_page(msp_account_id) unless relationship

      account_scope = managed_account_scope(msp_account_id)
      if actor && actor != "IAM_SYSTEM"
        # The count describes the whole collection, not only this page. Prove
        # authority for every target before disclosing IDs, counts or continuance.
        account_scope.pluck(:account_id).map(&:to_s).uniq.each_slice(batch_size) do |ids|
          raise AuthorizationDenied unless User.user_can(actor, "Account", "account.read", ids)
        end
      end
      total_count = account_scope.count(:account_id)
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

    def batch_size
      IamDemo.batch_size
    end

    def require_internal_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
    end

    def managed_account_scope(msp_account_id)
      OrganizationAccount
        .joins("INNER JOIN msp_managed_organizations ON msp_managed_organizations.client_organization_id = organization_accounts.organization_id")
        .where(msp_managed_organizations: { msp_account_id: msp_account_id })
        .distinct.order(:account_id)
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
