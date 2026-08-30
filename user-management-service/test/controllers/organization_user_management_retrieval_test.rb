require "test_helper"
require "minitest/mock"

class OrganizationUserManagementRetrievalTest < ActiveSupport::TestCase
  ACTOR_ID = "00000000-0000-4000-8000-000000000001"
  ORGANIZATION_ID = "00000000-0000-4000-8000-000000000002"
  ACCOUNT_IDS = [
    "00000000-0000-4000-8000-000000000003",
    "00000000-0000-4000-8000-000000000004"
  ].freeze

  test "serial and batched modes return equivalent organization partitions" do
    batched_payload, batched_calls = payload_for("batched")
    serial_payload, serial_calls = payload_for("serial")

    assert_equal "batched", batched_payload.delete(:retrieval_mode)
    assert_equal "serial", serial_payload.delete(:retrieval_mode)
    assert_equal batched_payload, serial_payload

    assert_equal [ACCOUNT_IDS], batched_calls.fetch(:accounts)
    assert_equal ACCOUNT_IDS, serial_calls.fetch(:accounts)
    assert_equal [ACCOUNT_IDS], batched_calls.fetch(:users)
    assert_equal ACCOUNT_IDS.map { |id| [id] }, serial_calls.fetch(:users)
    assert_equal [ACCOUNT_IDS], batched_calls.fetch(:groups)
    assert_equal ACCOUNT_IDS.map { |id| [id] }, serial_calls.fetch(:groups)
    assert_equal 1, batched_calls.fetch(:group_users).length
    assert_equal 2, serial_calls.fetch(:group_users).length
    assert batched_calls.fetch(:headers).all? { |headers| headers == { "pad-user-id" => ACTOR_ID } }
    assert serial_calls.fetch(:headers).all? { |headers| headers == { "pad-user-id" => ACTOR_ID } }
  end

  test "rejects an unknown retrieval mode" do
    old_mode = ENV["IAM_DEMO_RETRIEVAL_MODE"]
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = "parallel"
    controller = OrganizationUserManagementController.new

    error = assert_raises(OrganizationUserManagementController::InvalidRetrievalMode) do
      controller.send(:retrieval_mode)
    end
    assert_match(/serial or batched/, error.message)
  ensure
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = old_mode
  end

  private

  def payload_for(mode)
    old_mode = ENV["IAM_DEMO_RETRIEVAL_MODE"]
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = mode
    calls = { accounts: [], users: [], groups: [], group_users: [], headers: [] }
    accounts = ACCOUNT_IDS.map.with_index do |account_id, index|
      Account.new(id: account_id, name: "Account #{index + 1}", parent_account_id: nil)
    end
    users = ACCOUNT_IDS.map.with_index do |account_id, index|
      User.new(id: "00000000-0000-4000-8000-00000000001#{index}", account_id: account_id, email: "user#{index}@example.test")
    end
    groups = ACCOUNT_IDS.map.with_index do |account_id, index|
      Group.new(id: "00000000-0000-4000-8000-00000000002#{index}", account_id: account_id, name: "Group #{index + 1}")
    end
    group_users = users.each_with_index.map do |user, index|
      GroupUser.new(
        id: "00000000-0000-4000-8000-00000000003#{index}",
        user_id: user.id,
        group_id: groups[index].id
      )
    end
    with_headers = lambda do |headers, &block|
      calls[:headers] << headers
      block.call
    end
    account_search = lambda do |params|
      calls[:accounts] << params.fetch(:id)
      accounts.select { |account| params.fetch(:id).include?(account.id) }
    end
    account_find = lambda do |account_id|
      calls[:accounts] << account_id
      accounts.find { |account| account.id == account_id }
    end
    user_search = lambda do |params|
      ids = params.fetch(:account_id)
      calls[:users] << ids
      users.select { |user| ids.include?(user.account_id) }
    end
    group_search = lambda do |params|
      ids = params.fetch(:account_id)
      calls[:groups] << ids
      groups.select { |group| ids.include?(group.account_id) }
    end
    group_user_search = lambda do |params|
      ids = params.fetch(:user_id)
      calls[:group_users] << ids
      group_users.select { |group_user| ids.include?(group_user.user_id) }
    end

    payload = Account.stub(:with_headers, with_headers) do
      User.stub(:with_headers, with_headers) do
        Group.stub(:with_headers, with_headers) do
          GroupUser.stub(:with_headers, with_headers) do
            Account.stub(:search, account_search) do
              Account.stub(:find, account_find) do
                User.stub(:search, user_search) do
                  Group.stub(:search, group_search) do
                    GroupUser.stub(:search, group_user_search) do
                      controller = OrganizationUserManagementController.new
                      controller.instance_variable_set(:@actor_user_id, ACTOR_ID)
                      controller.instance_variable_set(:@organization_id, ORGANIZATION_ID)
                      controller.instance_variable_set(:@mode, "organization")
                      controller.send(:data_payload, account_ids: ACCOUNT_IDS, total_account_count: ACCOUNT_IDS.length)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    [payload, calls]
  ensure
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = old_mode
  end
end
