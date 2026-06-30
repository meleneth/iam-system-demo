# app/controllers/accounts/users_counts_controller.rb
# frozen_string_literal: true
class GroupsCountsController < ApplicationController
  # GET /accounts/users/counts?ids[]=acct1&ids[]=acct2
  def index
    ids = Array(params[:account_id]).map!(&:to_s).uniq
    return render json: { counts: {} }, status: :ok if ids.empty?
    auth = authorize_account_group_counts!(ids)
    return render json: auth, status: :accepted if auth

    # Pure SQL aggregate: SELECT account_id, COUNT(*) FROM users WHERE account_id IN (...) GROUP BY account_id
    raw = Group.where(account_id: ids).group(:account_id).count(:id) # => { "acct-uuid" => 123, ... }

    # Fill zeros for requested ids with no rows
    counts = ids.index_with(0).merge(raw.transform_keys!(&:to_s).transform_values!(&:to_i))

    render json: counts, status: :ok
  end

  private

  def authorize_account_group_counts!(account_ids)
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    if User.user_can(user_id, "Account", "account.users.read", account_ids)
      return
    end

    raise "no authorization for #{user_id} account.users.read #{account_ids}"
  end
end
