# app/controllers/accounts/users_counts_controller.rb
# frozen_string_literal: true
class GroupsCountsController < ApplicationController
  # GET /accounts/users/counts?ids[]=acct1&ids[]=acct2
  def index
    ids = Array(params[:account_id]).map!(&:to_s).uniq
    return render json: { counts: {} }, status: :ok if ids.empty?
    raw = Group.authorized_read("counts", records: ids.map { |id| Group.new(account_id: id) }) do
      Group.where(account_id: ids).group(:account_id).count(:id)
    end

    # Fill zeros for requested ids with no rows
    counts = ids.index_with(0).merge(raw.transform_keys!(&:to_s).transform_values!(&:to_i))

    render json: counts, status: :ok
  end
end
