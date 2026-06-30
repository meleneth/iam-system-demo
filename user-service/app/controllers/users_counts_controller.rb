# app/controllers/accounts/users_counts_controller.rb
# frozen_string_literal: true
class UsersCountsController < ApplicationController
  # GET /accounts/users/counts?ids[]=acct1&ids[]=acct2
  def index
    ids = Array(params[:account_id]).map!(&:to_s).uniq
    return render json: { counts: {} }, status: :ok if ids.empty?
    auth = authorize_account_user_counts!(ids)
    return if performed?
    return render json: auth, status: :accepted if auth

    # Pure SQL aggregate: SELECT account_id, COUNT(*) FROM users WHERE account_id IN (...) GROUP BY account_id
    raw = User.where(account_id: ids).group(:account_id).count(:id) # => { "acct-uuid" => 123, ... }

    # Fill zeros for requested ids with no rows
    counts = ids.index_with(0).merge(raw.transform_keys!(&:to_s).transform_values!(&:to_i))

    render json: counts, status: :ok
  end

  private

  def authorize_account_user_counts!(account_ids)
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    return if User.user_can?(user_id: user_id, permission: "account.users.read", account_ids: account_ids)

    render json: { error: "forbidden" }, status: :forbidden
  end
end
