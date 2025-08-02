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
      accounts_to_check = Array(scope_id)
      user_grants_key = cached_user_grants(user_id, permission)

      all_accounts_authorized = accounts_to_check.all? do |account_to_check|
        authorized = false
        Account.with_headers("pad-user-id" => "IAM_SYSTEM") do
          Account.with_parents(account_to_check).each do |account|
            if AUTHORIZATION_CACHE.sismember(user_grants_key, account.id)
              authorized = true
              break
            end
          end
        end
        authorized
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

private

def cached_user_grants(user_id, permission)
  key = "user_grants:#{user_id}:#{permission}"
  unless AUTHORIZATION_CACHE.exists?(key)
    scope_ids = CapabilityGrant.where(
      user_id: user_id,
      permission: permission,
      scope_type: "Account"
    ).pluck(:scope_id)
    AUTHORIZATION_CACHE.sadd(key, scope_ids) unless scope_ids.empty?
    AUTHORIZATION_CACHE.expire(key, 300)
  end
  key
end

