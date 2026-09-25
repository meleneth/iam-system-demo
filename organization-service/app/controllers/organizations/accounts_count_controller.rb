# app/controllers/organizations/accounts_count_controller.rb
# frozen_string_literal: true
class Organizations::AccountsCountController < ApplicationController
  def index
    org_id = params[:organization_id].to_s
    # Minimal sanity check (optional)
    unless org_id.match?(/\A[0-9a-fA-F-]{36}\z/)
      return render json: { error: "invalid organization id" }, status: :bad_request
    end

    target = OrganizationAccount.new(organization_id: org_id)
    organization_read = OrganizationAccount.authorization_requirement(
      "organization.read.accounts", scope_type: "Organization", target: :organization_id
    )
    count = OrganizationAccount.authorized_read(
      "accounts_count", records: [target], requirement: organization_read
    ) do
      OrganizationAccount.where(organization_id: org_id)
                         .distinct
                         .count(:account_id)
    end

    render json: { organization_id: org_id, accounts_count: count }, status: :ok
  end
end
