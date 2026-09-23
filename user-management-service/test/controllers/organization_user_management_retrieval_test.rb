require "test_helper"
require "minitest/mock"

class OrganizationUserManagementRetrievalTest < ActiveSupport::TestCase
  ACTOR_ID = "00000000-0000-4000-8000-000000000001"
  ORGANIZATION_ID = "00000000-0000-4000-8000-000000000002"
  GROUP_IDS = %w[00000000-0000-4000-8000-000000000020 00000000-0000-4000-8000-000000000021].freeze
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
    assert_equal [GROUP_IDS.reverse], batched_calls.fetch(:groups)
    assert_equal GROUP_IDS.reverse.map { |id| [id] }, serial_calls.fetch(:groups)
    assert_equal 1, batched_calls.fetch(:group_users).length
    assert_equal 2, serial_calls.fetch(:group_users).length
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

  test "account failures propagate in both retrieval modes including after serial progress" do
    old_mode = ENV["IAM_DEMO_RETRIEVAL_MODE"]
    controller = OrganizationUserManagementController.new
    %w[serial batched].each do |mode|
      ENV["IAM_DEMO_RETRIEVAL_MODE"] = mode
      [ActiveResource::ForbiddenAccess, ActiveResource::ServerError, RuntimeError].each do |error_class|
        calls = 0
        fetch = lambda do |*|
          calls += 1
          if mode == "serial" && calls == 1
            Account.new(id: ACCOUNT_IDS.first)
          else
            raise error_class.new(nil)
          end
        end
        Account.stub(:find, fetch) do
          Account.stub(:search, fetch) do
            assert_raises(error_class) { controller.send(:accounts_for, ACCOUNT_IDS) }
          end
        end
      end
    end
  ensure
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = old_mode
  end

  test "batched account reads reject incomplete and unexpected results" do
    old_mode = ENV["IAM_DEMO_RETRIEVAL_MODE"]
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = "batched"
    controller = OrganizationUserManagementController.new
    [[], [ACCOUNT_IDS.first], [ACCOUNT_IDS.first, ACCOUNT_IDS.first], [ACCOUNT_IDS.first, "other"]].each do |ids|
      Account.stub(:search, ids.map { |id| Account.new(id: id) }) do
        assert_raises(OrganizationUserManagementController::IncompleteResponse) do
          controller.send(:accounts_for, ACCOUNT_IDS)
        end
      end
    end
  ensure
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = old_mode
  end

  test "cross-account memberships return the same groups across account pages" do
    %w[serial batched].each do |mode|
      whole, = payload_for(mode)
      pages = ACCOUNT_IDS.flat_map { |id| payload_for(mode, account_ids: [id]).first.fetch(:users) }
      assert_equal whole.fetch(:users), pages
      assert_equal GROUP_IDS.reverse, pages.map { |user| user.fetch("groups").sole.fetch("id") }
    end
  end

  test "group authorization failures propagate with the original actor" do
    %w[serial batched].each do |mode|
      assert_raises(ActiveResource::ForbiddenAccess) { payload_for(mode, deny_groups: true) }
    end
  end

  private

  def payload_for(mode, account_ids: ACCOUNT_IDS, deny_groups: false)
    old_mode = ENV["IAM_DEMO_RETRIEVAL_MODE"]
    ENV["IAM_DEMO_RETRIEVAL_MODE"] = mode
    calls = { accounts: [], users: [], groups: [], group_users: [] }
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
        group_id: groups[1 - index].id
      )
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
      raise ActiveResource::ForbiddenAccess.new(nil) if deny_groups
      ids = params.fetch(:id)
      calls[:groups] << ids
      groups.select { |group| ids.include?(group.id) }
    end
    group_user_search = lambda do |params|
      ids = params.fetch(:user_id)
      calls[:group_users] << ids
      group_users.select { |group_user| ids.include?(group_user.user_id) }
    end

    payload = AuthorizationContext.as_requesting_user(user_id: ACTOR_ID) do
      Account.stub(:search, account_search) do
        Account.stub(:find, account_find) do
          User.stub(:search, user_search) do
            Group.stub(:search, group_search) do
              GroupUser.stub(:search, group_user_search) do
                controller = OrganizationUserManagementController.new
                controller.instance_variable_set(:@actor_user_id, ACTOR_ID)
                controller.instance_variable_set(:@organization_id, ORGANIZATION_ID)
                controller.instance_variable_set(:@mode, "organization")
                controller.send(:data_payload, account_ids: account_ids, total_account_count: ACCOUNT_IDS.length)
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
