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
end
