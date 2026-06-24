# frozen_string_literal: true

module Internal
  class MspManagedAccountsController < ApplicationController
    DEFAULT_LIMIT = 1_000
    MAX_LIMIT = 5_000

    def index
      msp_account_id = params.require(:msp_account_id)
      limit = [[params.fetch(:limit, DEFAULT_LIMIT).to_i, 1].max, MAX_LIMIT].min
      offset = [params.fetch(:offset, 0).to_i, 0].max

      scope = MspManagedAccount.where(msp_account_id: msp_account_id)
      render json: {
        msp_account_id: msp_account_id,
        total_count: scope.count,
        offset: offset,
        limit: limit,
        managed_account_ids: scope.order(:managed_account_id).offset(offset).limit(limit).pluck(:managed_account_id)
      }
    end

    def show
      render json: {
        msp_account_id: params.require(:msp_account_id),
        managed_account_id: params.require(:managed_account_id),
        managed: MspManagedAccount.exists?(
          msp_account_id: params.require(:msp_account_id),
          managed_account_id: params.require(:managed_account_id)
        )
      }
    end
  end
end
