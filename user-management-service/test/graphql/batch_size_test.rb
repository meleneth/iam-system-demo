require "test_helper"
require "minitest/mock"

class BatchSizeTest < ActiveSupport::TestCase
  setup do
    @previous = ENV["IAM_DEMO_BATCH_SIZE"]
    ENV["IAM_DEMO_BATCH_SIZE"] = "2"
    @context = OpenTelemetry::Context.current
    @tracer = OpenTelemetry.tracer_provider.tracer("test")
  end

  teardown { ENV["IAM_DEMO_BATCH_SIZE"] = @previous }

  test "validates the environment and supplies the documented default" do
    ["0", "-1", "wat", "2.5", "10001", ""].each do |value|
      ENV["IAM_DEMO_BATCH_SIZE"] = value
      assert_raises(IamDemo::InvalidBatchSize) { IamDemo.batch_size }
    end
    ENV.delete("IAM_DEMO_BATCH_SIZE")
    assert_equal 1000, IamDemo.batch_size
  end

  test "Account source uses configured POST chunks and preserves order" do
    calls = Queue.new
    search = lambda do |params|
      ids = params.fetch(:id)
      calls << ids
      ids.reverse.map { |id| Account.new(id: id) }
    end
    Account.stub(:search, search) do
      result = Sources::AccountById.new(as: "actor", otel_ctx: @context).fetch(%w[a b c a])
      assert_equal %w[a b c a], result.map(&:id)
    end
    assert_equal [%w[a b], %w[c]].sort, Array.new(calls.size) { calls.pop }.sort
  end

  test "Users and both Group stages use configured chunks" do
    user_calls = []
    User.stub(:search, ->(params) { user_calls << params.fetch(:account_id); [] }) do
      source = Sources::UsersByAccountId.new(as: "actor", otel_ctx: @context, tracer: @tracer)
      assert_equal [[], [], []], source.fetch(%w[a b c])
    end
    assert_equal [%w[a b], %w[c]], user_calls

    membership_calls, group_calls = [], []
    memberships = lambda do |params|
      membership_calls << params.fetch(:user_id)
      params.fetch(:user_id).map { |id| GroupUser.new(user_id: id, group_id: "group-#{id}") }
    end
    groups = lambda do |params|
      group_calls << params.fetch(:id)
      params.fetch(:id).map { |id| Group.new(id: id) }
    end
    GroupUser.stub(:search, memberships) do
      Group.stub(:search, groups) do
        source = Sources::GroupsByUserId.new(as: "actor", otel_ctx: @context, tracer: @tracer)
        assert_equal [["group-a"], ["group-b"], ["group-c"]], source.fetch(%w[a b c]).map { |rows| rows.map(&:id) }
      end
    end
    assert_equal [%w[a b], %w[c]], membership_calls
    assert_equal [%w[group-a group-b], %w[group-c]], group_calls
  end

  test "count sources apply the actor to every configured chunk" do
    [[Sources::UsersCountByAccount, User, :users_count], [Sources::GroupsCountByAccount, Group, :groups_count]].each do |source_class, model, method|
      calls = []
      model.stub(method, lambda { |ids|
        calls << [ids, model.headers["pad-user-id"]]
        ids.to_h { |id| [id.to_sym, 3] }
      }) do
        source = source_class.new(as: "actor", otel_ctx: @context, tracer: @tracer)
        assert_equal [3, 3, 3], source.fetch(%w[a b c])
      end
      assert_equal [[%w[a b], "actor"], [%w[c], "actor"]], calls
    end
  end

  test "hierarchy client sends JSON POST chunks and restores input ordering" do
    calls = []
    authorization_calls = []
    authorization_client = Object.new
    authorization_client.define_singleton_method(:capabilities) do |targets|
      authorization_calls << targets.map(&:scope_id)
      { "Account" => targets.to_h { |target| [target.scope_id, ["account.read"]] } }
    end
    connection = Object.new
    connection.define_singleton_method(:post) do |path, body, headers|
      ids = JSON.parse(body).fetch("account_ids")
      calls << [path, ids, headers.fetch("Content-Type")]
      Struct.new(:body).new(ids.reverse.map { |id| [{ id: id }] }.to_json)
    end
    Account.stub(:connection, connection) do
      AuthorizedResource.stub(:authorization_client, authorization_client) do
        AuthorizationContext.as_requesting_user(user_id: "actor") do
          assert_equal [%w[c], %w[a], %w[b], %w[c]], Account.with_parents_batch_ordered(%w[c a b c]).map { |rows| rows.map(&:id) }
        end
      end
    end
    assert_equal [["/accounts_with_parents", %w[c a], "application/json"], ["/accounts_with_parents", %w[b], "application/json"]], calls
    assert_equal [%w[a c], %w[b]], authorization_calls
  end

  test "organization partitions and join lookups use configured size" do
    controller = OrganizationUserManagementController.new
    payload = ->(account_ids:, total_account_count:) { { ids: account_ids, total: total_account_count } }
    controller.stub(:organization_account_ids, %w[a b c]) do
      controller.stub(:data_payload, payload) do
        page = controller.send(:organization_partition, nil)
        assert_equal %w[a b], page.fetch(:payload).fetch(:ids)
        assert_equal({ "index" => 2 }, page.fetch(:next_cursor))
      end
    end
    controller.stub(:serial_retrieval?, false) do
      calls = []
      User.stub(:search, ->(params) { calls << params.fetch(:account_id); [] }) do
        controller.send(:retrieve_by_join_key, User, :account_id, %w[a b c])
      end
      assert_equal [%w[a b], %w[c]], calls
    end
  end
end
