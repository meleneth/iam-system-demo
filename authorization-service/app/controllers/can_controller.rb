class CanController < ApplicationController
  def index
    permitted = params.permit(:scope_type, :permission, scope_id: [])
    scope_type = permitted[:scope_type]
    permission = permitted[:permission]
    scope_id   = permitted[:scope_id]

    user_id = request.headers["HTTP_PAD_USER_ID"]

    if user_id == "IAM_SYSTEM"
      return head :ok
    end
    authorized = false

    case scope_type
    when "Account"
      msp_result = msp_reflected_account_user_management_check(user_id, permission, scope_id)
      if msp_result
        return render json: msp_result, status: :accepted if msp_result[:loading]
        return head :ok if msp_result[:authorized]
      end

      hierarchies = nil
      Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
        hierarchies = Account.with_parents_batch(scope_id) # returns [[Account, Account...], ...]
      end

      checker = Authorization::AccountGrantChecker.new(
        user_id: user_id,
        permission: permission,
        redis: AUTHORIZATION_CACHE
      )

      if checker.authorized_for_all?(hierarchies)
        authorized = true
      end
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

  private

  def msp_reflected_account_user_management_check(user_id, permission, scope_ids)
    msp_account_id = request.headers["HTTP_PAD_MSP_ACCOUNT_ID"]
    return nil unless msp_account_id.present?
    return nil unless ["account.users.read", "account.users.create"].include?(permission)

    account_ids = Array(scope_ids).map(&:to_s).uniq
    result = Authorization::MspReflectedUserGrants.new.check(
      user_id: user_id,
      msp_account_id: msp_account_id,
      account_ids: account_ids
    )

    result.merge(authorized: (account_ids - Array(result[:authorized_account_ids]).map(&:to_s)).empty?)
  end
end
