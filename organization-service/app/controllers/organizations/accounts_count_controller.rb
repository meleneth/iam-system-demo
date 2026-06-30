# app/controllers/organizations/accounts_count_controller.rb
# frozen_string_literal: true
class Organizations::AccountsCountController < ApplicationController
  def index
    org_id = params[:organization_id].to_s
    # Minimal sanity check (optional)
    unless org_id.match?(/\A[0-9a-fA-F-]{36}\z/)
      return render json: { error: "invalid organization id" }, status: :bad_request
    end

    pad_user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless pad_user_id

    if pad_user_id != "IAM_SYSTEM" && !organization_accounts_read?(pad_user_id, org_id)
      raise "no authorization for #{pad_user_id} organization.read.accounts #{org_id}"
    end

    count = OrganizationAccount.where(organization_id: org_id)
                               .distinct
                               .count(:account_id)  # DB-native COUNT(DISTINCT account_id)

    render json: { organization_id: org_id, accounts_count: count }, status: :ok
  end

  private

  def organization_accounts_read?(pad_user_id, organization_id)
    User.user_can(pad_user_id, "Organization", "organization.read.accounts", organization_id) ||
      User.user_can(pad_user_id, "Organization", "organization.accounts.read", organization_id)
  end
end
