# frozen_string_literal: true

class MspReflectedUserGrantsController < ApplicationController
  def check
    permitted = params.permit(:user_id, :msp_account_id, account_ids: [])
    account_ids = permitted[:account_ids]
    raise ActionController::BadRequest, "account_ids must be an array" unless account_ids.is_a?(Array)

    result = Authorization::MspReflectedUserGrants.new.check(
      user_id: permitted.require(:user_id),
      msp_account_id: permitted.require(:msp_account_id),
      account_ids: account_ids
    )

    status = result[:loading] ? :accepted : :ok
    render json: result, status: status
  end
end
