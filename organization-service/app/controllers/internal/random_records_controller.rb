# frozen_string_literal: true

module Internal
  class RandomRecordsController < ApplicationController
    def organization
      return unless require_iam_system!

      record = random_record(Organization.all)
      return render json: { error: "No organizations found" }, status: :not_found unless record

      render json: record
    end

    def organization_account
      return unless require_iam_system!

      organization_id = params.require(:organization_id)
      scope = OrganizationAccount.where(organization_id: organization_id)
      record = random_record(scope)
      return render json: { error: "No accounts found for organization #{organization_id}" }, status: :not_found unless record

      render json: {
        organization_id: record.organization_id,
        account_id: record.account_id,
        accounts_count: scope.count
      }
    end

    private

    def require_iam_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
      false
    end

    def random_record(scope)
      total = scope.count
      return nil if total.zero?

      scope.offset(rand(total)).limit(1).first
    end
  end
end
