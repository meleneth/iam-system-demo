# frozen_string_literal: true

require "set"

module Internal
  module Auth
    class AccountContextsController < ApplicationController
      def create
        return unless require_iam_system_auth!

        render json: { accounts: account_contexts }
      end

      def providers
        return unless require_iam_system_auth!
        ids = params.permit(account_ids: [])[:account_ids]
        raise ActionController::BadRequest, "account_ids must be an array" unless ids.is_a?(Array)

        rows = OrganizationAccount.authorized_internal_read("auth_account_providers", identities: %w[IAM_SYSTEM_AUTH]) do
          OrganizationAccount
            .joins("INNER JOIN msp_managed_organizations managed ON managed.client_organization_id = organization_accounts.organization_id")
            .joins("INNER JOIN organization_accounts provider ON provider.account_id = managed.msp_account_id AND provider.organization_id = managed.msp_organization_id")
            .where(account_id: ids)
            .pluck("organization_accounts.account_id", "managed.msp_account_id", "managed.msp_organization_id", "managed.client_organization_id")
        end
        render json: {accounts: rows.map { |account, provider, msp, client| {account_id: account, msp_account_id: provider, msp_organization_id: msp, client_organization_id: client} }}
      end

      private

      def require_iam_system_auth!
        return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM_AUTH"

        render json: { error: "IAM_SYSTEM_AUTH required" }, status: :forbidden
        false
      end

      def account_contexts
        contexts.flat_map do |context|
          next [] unless msp_account_in_organization?(context)

          relationships = MspManagedOrganization.authorized_internal_read("auth_relationships", identities: %w[IAM_SYSTEM_AUTH]) do
            MspManagedOrganization
              .where(
                msp_organization_id: context.fetch(:msp_organization_id),
                msp_account_id: context.fetch(:msp_account_id)
              )
              .index_by { |relationship| relationship.client_organization_id.to_s }
          end

          context.fetch(:accounts).filter_map do |account|
            target_org_account = OrganizationAccount.authorized_internal_read("auth_account_owner", identities: %w[IAM_SYSTEM_AUTH]) do
              OrganizationAccount.find_by(account_id: account.fetch(:account_id))
            end
            next unless target_org_account

            client_organization_id = target_org_account.organization_id.to_s
            next unless relationships.key?(client_organization_id)

            client_account_ids = account_ids_for_organization(client_organization_id)
            next unless client_account_ids.include?(account.fetch(:account_id))

            {
              msp_organization_id: context.fetch(:msp_organization_id),
              msp_account_id: context.fetch(:msp_account_id),
              client_organization_id: client_organization_id,
              account_id: account.fetch(:account_id),
              parent_account_ids: account.fetch(:parent_account_ids).select { |account_id| client_account_ids.include?(account_id) }
            }
          end
        end
      end

      def contexts
        params.require(:contexts).map do |raw_context|
          context = raw_context.permit(:msp_organization_id, :msp_account_id, accounts: [:account_id, { parent_account_ids: [] }])
          {
            msp_organization_id: context.require(:msp_organization_id).to_s,
            msp_account_id: context.require(:msp_account_id).to_s,
            accounts: Array(context[:accounts]).map do |raw_account|
              account = raw_account.permit(:account_id, parent_account_ids: [])
              {
                account_id: account.require(:account_id).to_s,
                parent_account_ids: Array(account[:parent_account_ids]).map(&:to_s)
              }
            end
          }
        end
      end

      def msp_account_in_organization?(context)
        OrganizationAccount.authorized_internal_read("auth_provider_membership", identities: %w[IAM_SYSTEM_AUTH]) do
          OrganizationAccount.exists?(
            organization_id: context.fetch(:msp_organization_id),
            account_id: context.fetch(:msp_account_id)
          )
        end
      end

      def account_ids_for_organization(organization_id)
        OrganizationAccount.authorized_internal_read("auth_organization_accounts", identities: %w[IAM_SYSTEM_AUTH]) do
          OrganizationAccount.where(organization_id: organization_id).pluck(:account_id).map(&:to_s).to_set
        end
      end
    end
  end
end
