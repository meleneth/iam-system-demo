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
        organization_ids = OrganizationAccount.authorized_read(
          "msp_ownership",
          records: [OrganizationAccount.new(account_id: msp_account_id)],
          requirement: account_read_requirement
        ) do
          OrganizationAccount.where(account_id: msp_account_id).distinct.pluck(:organization_id)
        end
        raise AuthorizationDenied unless relationship && organization_ids == [relationship.msp_organization_id]
      end
      return render json: empty_page(msp_account_id) unless relationship

      account_scope = managed_account_scope(msp_account_id)
      total_count = OrganizationAccount.authorized_read(
        "managed_accounts_count",
        records: [OrganizationAccount.new(account_id: msp_account_id)],
        requirement: account_read_requirement
      ) do
        account_scope.unscope(:order).count(:account_id)
      end
      relationships = OrganizationAccount.authorized_read(
        "managed_accounts",
        requirement: account_read_requirement
      ) { account_scope.offset(offset).limit(limit).to_a }
      account_ids = relationships.map { |row| row.account_id.to_s }
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

    def account_read_requirement
      OrganizationAccount.authorization_requirement("account.read", scope_type: "Account", target: :account_id)
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
