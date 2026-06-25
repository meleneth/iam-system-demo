# frozen_string_literal: true

require "base64"

module Internal
  class MspManagedAccountsController < ApplicationController
    PAGE_SIZE = 500

    def index
      return unless require_iam_system!

      msp_account_id = params.require(:msp_account_id)
      after_managed_account_id = decode_continuance(params[:continuance])
      scope = MspManagedAccount.where(msp_account_id: msp_account_id).order(:managed_account_id)
      scope = scope.where("managed_account_id > ?", after_managed_account_id) if after_managed_account_id.present?
      fetched_account_ids = scope.limit(PAGE_SIZE + 1).pluck(:managed_account_id)
      managed_account_ids = fetched_account_ids.first(PAGE_SIZE)

      render json: {
        msp_account_id: msp_account_id,
        total_count: MspManagedAccount.where(msp_account_id: msp_account_id).count,
        continuance: continuance_for(managed_account_ids, has_next_page: fetched_account_ids.length > PAGE_SIZE),
        managed_account_ids: managed_account_ids
      }
    rescue JSON::ParserError, ArgumentError
      render json: { error: "Invalid continuance" }, status: :bad_request
    end

    def show
      return unless require_iam_system!

      render json: {
        msp_account_id: params.require(:msp_account_id),
        managed_account_id: params.require(:managed_account_id),
        managed: MspManagedAccount.exists?(
          msp_account_id: params.require(:msp_account_id),
          managed_account_id: params.require(:managed_account_id)
        )
      }
    end

    def manager
      return unless require_iam_system!

      managed_account_id = params.require(:managed_account_id)
      mapping = MspManagedAccount.where(managed_account_id: managed_account_id).order(:msp_account_id).first

      render json: {
        managed_account_id: managed_account_id,
        managed: mapping.present?,
        msp_account_id: mapping&.msp_account_id
      }
    end

    private

    def require_iam_system!
      return true if request.headers["HTTP_PAD_USER_ID"] == "IAM_SYSTEM"

      render json: { error: "IAM_SYSTEM required" }, status: :forbidden
      false
    end

    def decode_continuance(continuance)
      return nil if continuance.blank?

      payload = JSON.parse(Base64.urlsafe_decode64(padded_continuance(continuance)))
      raise ArgumentError, "Unsupported continuance" unless payload["v"] == 1

      payload["after"]
    end

    def continuance_for(managed_account_ids, has_next_page:)
      return nil unless has_next_page

      Base64.urlsafe_encode64(JSON.dump({ "v" => 1, "after" => managed_account_ids.last }), padding: false)
    end

    def padded_continuance(continuance)
      continuance + ("=" * ((4 - continuance.length % 4) % 4))
    end
  end
end
