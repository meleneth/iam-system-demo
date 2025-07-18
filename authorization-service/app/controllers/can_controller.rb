class CanController < ApplicationController
  def index
    permitted = params.permit(:scope_type, :permission, scope_id: [])
    scope_type = permitted[:scope_type]
    permission = permitted[:permission]
    scope_id   = permitted[:scope_id]

    user_id = request.headers["HTTP_PAD_USER_ID"]

    if user_id == "IAM_SYSTEM"
      # System user bypasses all checks
      return head :ok
    end
    authorized = false

    case scope_type
    when "Account"
      accounts_to_check = scope_id
      all_accounts_authorized = true
      accounts_to_check.each do |account_to_check|
        sub_account_hierarchy = false
        sub_account_authorized = false
        Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
          sub_account_hierarchy = Account.with_parents(account_to_check)
        end
        sub_account_hierarchy.each do |account|
          sub_account_authorized = true if CapabilityGrant.exists?(
            user_id: user_id,
            permission: permission,
            scope_type: "Account",
            scope_id: account.id
          )
        end
        all_accounts_authorized = false unless sub_account_authorized
      end
      return head :ok if all_accounts_authorized
    when "Organization"
      # No hierarchy, just one org
      authorized = CapabilityGrant.exists?(
        user_id: user_id,
        permission: permission,
        scope_type: "Organization",
        scope_id: scope_id
      )
    when "System"
      authorized = CapabilityGrant.exists?(
        user_id: user_id,
        permission: permission,
        scope_type: "System",
        scope_id: nil
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
