# frozen_string_literal: true

# These are authorization computations, independent of the controller/transport.
module AuthorizationOperations
  def for_account(account_id)
    Instrumentation.trace("authorization.capabilities.account", attributes: { "scope.id" => account_id }) { super }
  end

  def for_organization(organization_id)
    Instrumentation.trace("authorization.capabilities.organization", attributes: { "scope.id" => organization_id }) { super }
  end

  def account_ids_with_permission(account_ids, permission)
    attributes = { "authorization.permission" => permission, "scope.count" => Array(account_ids).size }
    attributes["scope.id"] = Array(account_ids).first if Array(account_ids).size == 1
    Instrumentation.trace("authorization.permission.accounts", attributes: attributes) { super }
  end
end

Rails.application.reloader.to_prepare do
  Authorization::Capabilities.prepend(AuthorizationOperations)
end
