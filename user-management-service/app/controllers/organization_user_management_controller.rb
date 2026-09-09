# frozen_string_literal: true

require "base64"

class OrganizationUserManagementController < ApplicationController
  ACCOUNT_PARTITION_SIZE = 5000
  VISIBLE_PARTITION_LABEL = "server-fixed"
  RETRIEVAL_MODES = %w[serial batched].freeze

  class InvalidRetrievalMode < StandardError; end
  class IncompleteResponse < StandardError; end

  def show
    permitted = params.permit(:organization_id, :as)
    @actor_user_id = permitted.require(:as)
    @organization_id = permitted.require(:organization_id)
    @mode = "organization"
    @title = "Organization User Management"
    @partition_path = organization_user_management_partition_path(
      organization_id: @organization_id,
      as: @actor_user_id,
      frame_id: "organization-user-management-partition-root"
    )
  end

  def partition
    permitted = params.permit(:organization_id, :as, :continuance, :frame_id)
    @actor_user_id = permitted.require(:as)
    @organization_id = permitted.require(:organization_id)
    @mode = "organization"
    @frame_id = permitted[:frame_id].presence || "organization-user-management-partition-root"

    cursor = decode_continuance(permitted[:continuance])
    partition = organization_partition(cursor)

    @partition_payload = partition.fetch(:payload)
    @next_continuance = encode_continuance(partition.fetch(:next_cursor)) if partition[:next_cursor]
    @partition_label = partition.fetch(:label)
    @next_frame_id = "organization-user-management-partition-#{@next_continuance || "done"}"

    render partial: "organization_user_management/partition"
  rescue JSON::ParserError, ArgumentError
    render plain: "Invalid continuance", status: :bad_request
  end

  private

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
      group = group_names_by_id.fetch(group_user.fetch("group_id"))
      memo[group_user.fetch("user_id")] << group
    end
    accounts_by_id = accounts_for(account_ids).index_by { |account| account.fetch("id") }

    {
      mode: @mode,
      loading: false,
      actor_user_id: @actor_user_id,
      organization_id: @organization_id,
      retrieval_mode: retrieval_mode,
      total_account_count: total_account_count,
      partition_account_count: account_ids.length,
      accounts: account_ids.map { |account_id| accounts_by_id.fetch(account_id) },
      users: users.map do |user|
        account = accounts_by_id.fetch(user.fetch("account_id").to_s)
        user.merge(
          "account" => account,
          "groups" => groups_by_user_id[user.fetch("id").to_s] || []
        )
      end
    }
  end

  def users_for(account_ids)
    return [] if account_ids.empty?

    User.with_headers(service_headers) do
      retrieve_by_join_key(User, :account_id, account_ids).map { |user| resource_attributes(user) }
    end
  end

  def groups_for(account_ids)
    return [] if account_ids.empty?

    Group.with_headers(service_headers) do
      retrieve_by_join_key(Group, :account_id, account_ids).map { |group| resource_attributes(group) }
    end
  end

  def group_users_for(user_ids)
    return [] if user_ids.empty?

    GroupUser.with_headers(service_headers) do
      retrieve_by_join_key(GroupUser, :user_id, user_ids).map { |group_user| resource_attributes(group_user) }
    end
  end

  def accounts_for(account_ids)
    return [] if account_ids.empty?

    Account.with_headers(service_headers) do
      accounts = if serial_retrieval?
        account_ids.map { |account_id| Account.find(account_id) }
      else
        Account.search(id: account_ids)
      end
      returned_ids = accounts.map { |account| account.id.to_s }
      unless returned_ids.sort == account_ids.map(&:to_s).sort
        raise IncompleteResponse, "Account Service returned an incomplete or unexpected account set"
      end
      accounts.map { |account| resource_attributes(account) }
    end
  end

  def service_headers
    { "pad-user-id" => @actor_user_id }
  end

  def retrieve_by_join_key(resource_class, join_key, ids)
    return resource_class.search(join_key => ids) unless serial_retrieval?

    ids.flat_map { |id| resource_class.search(join_key => [id]) }
  end

  def serial_retrieval?
    retrieval_mode == "serial"
  end

  def retrieval_mode
    mode = ENV.fetch("IAM_DEMO_RETRIEVAL_MODE", "batched")
    return mode if RETRIEVAL_MODES.include?(mode)

    raise InvalidRetrievalMode, "IAM_DEMO_RETRIEVAL_MODE must be serial or batched, got #{mode.inspect}"
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
