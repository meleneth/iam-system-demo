# frozen_string_literal: true

require "base64"

class OrganizationUserManagementController < ApplicationController
  ACCOUNT_PARTITION_SIZE = 500
  VISIBLE_PARTITION_LABEL = "server-fixed"

  def show
    permitted = params.permit(:organization_id, :msp_account_id, :as)
    @actor_user_id = permitted.require(:as)
    @organization_id = permitted[:organization_id]
    @msp_account_id = permitted[:msp_account_id]
    @mode = @msp_account_id.present? ? "msp" : "organization"
    @title = @mode == "msp" ? "MSP User Management" : "Organization User Management"
    @partition_path = organization_user_management_partition_path(
      organization_id: @organization_id,
      msp_account_id: @msp_account_id,
      as: @actor_user_id,
      frame_id: "organization-user-management-partition-root"
    )
  end

  def partition
    permitted = params.permit(:organization_id, :msp_account_id, :as, :continuance, :frame_id)
    @actor_user_id = permitted.require(:as)
    @organization_id = permitted[:organization_id]
    @msp_account_id = permitted[:msp_account_id]
    @mode = @msp_account_id.present? ? "msp" : "organization"
    @frame_id = permitted[:frame_id].presence || "organization-user-management-partition-root"

    cursor = decode_continuance(permitted[:continuance])
    partition = @mode == "msp" ? msp_partition(cursor) : organization_partition(cursor)

    @partition_payload = partition.fetch(:payload)
    @next_continuance = encode_continuance(partition.fetch(:next_cursor)) if partition[:next_cursor]
    @partition_label = partition.fetch(:label)
    @next_frame_id = "organization-user-management-partition-#{@next_continuance || "done"}"

    render partial: "organization_user_management/partition"
  rescue MspReflectedGrantLoading => e
    @partition_payload = loading_payload(e.status)
    @partition_label = "MSP reflected grant status"
    @next_continuance = nil
    @next_frame_id = "organization-user-management-partition-done"
    render partial: "organization_user_management/partition", status: :accepted
  rescue JSON::ParserError, ArgumentError
    render plain: "Invalid continuance", status: :bad_request
  end

  private

  def msp_partition(cursor)
    page = MspManagedAccount.page(@msp_account_id, continuance: cursor&.fetch("msp_continuance", nil))
    account_ids = page.fetch("managed_account_ids").map(&:to_s)
    status = MspReflectedUserGrant.check(user_id: @actor_user_id, msp_account_id: @msp_account_id, account_ids: account_ids)

    if status.fetch(:loading) || status[:status] == "failed"
      return {
        label: "MSP reflected grant status",
        payload: loading_payload(status),
        next_cursor: nil
      }
    end

    authorized_account_ids = status.fetch(:authorized_account_ids).map(&:to_s)
    {
      label: "MSP account partition #{VISIBLE_PARTITION_LABEL}",
      payload: data_payload(account_ids: authorized_account_ids, total_account_count: status.fetch(:total_count)),
      next_cursor: page["continuance"].present? ? { "msp_continuance" => page.fetch("continuance") } : nil
    }
  end

  def organization_partition(cursor)
    account_ids = organization_account_ids
    index = cursor&.fetch("index", 0).to_i
    partition_account_ids = account_ids.slice(index, ACCOUNT_PARTITION_SIZE) || []
    next_index = index + partition_account_ids.length

    {
      label: "organization account partition #{index + 1}-#{next_index}",
      payload: data_payload(account_ids: partition_account_ids, total_account_count: account_ids.length),
      next_cursor: next_index < account_ids.length ? { "index" => next_index } : nil
    }
  end

  def organization_account_ids
    OrganizationAccount.with_headers("pad-user-id" => @actor_user_id) do
      OrganizationAccount.find(:all, params: { organization_id: @organization_id }).map { |link| link.account_id.to_s }
    end
  end

  def data_payload(account_ids:, total_account_count:)
    users = users_for(account_ids)
    groups = groups_for(account_ids)
    group_users = group_users_for(users.map { |user| user.fetch("id") })
    group_names_by_id = groups.index_by { |group| group.fetch("id") }
    groups_by_user_id = group_users.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |group_user, memo|
      group = group_names_by_id[group_user.fetch("group_id")]
      memo[group_user.fetch("user_id")] << group if group
    end
    accounts_by_id = accounts_for(account_ids).index_by { |account| account.fetch("id") }

    {
      mode: @mode,
      loading: false,
      actor_user_id: @actor_user_id,
      organization_id: @organization_id,
      msp_account_id: @msp_account_id,
      total_account_count: total_account_count,
      partition_account_count: account_ids.length,
      accounts: account_ids.map { |account_id| accounts_by_id[account_id] || { "id" => account_id, "name" => nil, "parent_account_id" => nil } },
      users: users.map do |user|
        account = accounts_by_id[user.fetch("account_id").to_s]
        user.merge(
          "account" => account || { "id" => user.fetch("account_id").to_s, "name" => nil, "parent_account_id" => nil },
          "groups" => groups_by_user_id[user.fetch("id").to_s] || []
        )
      end
    }
  end

  def loading_payload(status)
    status_name = status[:status] || status["status"]
    retry_path = status_name == "failed" ? nil : request.fullpath

    {
      mode: @mode,
      loading: true,
      actor_user_id: @actor_user_id,
      organization_id: @organization_id,
      msp_account_id: @msp_account_id,
      reflected_status: status_name,
      loaded_count: status.fetch(:loaded_count),
      total_count: status.fetch(:total_count),
      message: "Preparing MSP user-management access. Loaded #{status.fetch(:loaded_count)} of #{status.fetch(:total_count)} accounts.",
      retry_path: retry_path,
      retry_after_ms: 1500,
      accounts: [],
      users: []
    }
  end

  def users_for(account_ids)
    return [] if account_ids.empty?

    User.with_headers(service_headers) do
      User.search(account_id: account_ids).map { |user| resource_attributes(user) }
    end
  end

  def groups_for(account_ids)
    return [] if account_ids.empty?

    Group.with_headers(service_headers) do
      Group.search(account_id: account_ids).map { |group| resource_attributes(group) }
    end
  end

  def group_users_for(user_ids)
    return [] if user_ids.empty?

    GroupUser.with_headers(service_headers) do
      GroupUser.search(user_id: user_ids).map { |group_user| resource_attributes(group_user) }
    end
  end

  def accounts_for(account_ids)
    return [] if account_ids.empty?
    return account_ids.map { |account_id| { "id" => account_id.to_s } } if @msp_account_id.present?

    Account.with_headers("pad-user-id" => @actor_user_id) do
      Account.search(id: account_ids).map { |account| resource_attributes(account) }
    end
  rescue ActiveResource::ClientError, ActiveResource::ServerError, RuntimeError
    []
  end

  def service_headers
    headers = { "pad-user-id" => @actor_user_id }
    headers["pad-msp-account-id"] = @msp_account_id if @msp_account_id.present?
    headers
  end

  def resource_attributes(resource)
    attrs = resource.attributes.transform_keys(&:to_s)
    attrs["id"] ||= resource.id.to_s if resource.respond_to?(:id) && resource.id.present?
    attrs
  end

  def decode_continuance(continuance)
    return nil if continuance.blank?

    payload = JSON.parse(Base64.urlsafe_decode64(padded_continuance(continuance)))
    raise ArgumentError, "Unsupported continuance" unless payload["v"] == 1

    payload.fetch("cursor")
  end

  def encode_continuance(cursor)
    Base64.urlsafe_encode64(JSON.dump({ "v" => 1, "cursor" => cursor }), padding: false)
  end

  def padded_continuance(continuance)
    continuance + ("=" * ((4 - continuance.length % 4) % 4))
  end
end
