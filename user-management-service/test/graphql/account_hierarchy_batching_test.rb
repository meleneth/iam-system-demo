require "test_helper"
require "minitest/mock"

class AccountHierarchyBatchingTest < ActiveSupport::TestCase
  ACTOR_ID = "actor-1"

  test "accountHierarchies makes one batch request and restores requested order" do
    calls = []
    batch = lambda do |ids|
      calls << ids
      [
        [Account.new(id: "second", name: "Second")],
        [Account.new(id: "first", name: "First")]
      ]
    end

    Account.stub(:with_headers, ->(*, &block) { block.call }) do
      Account.stub(:with_parents_batch, batch) do
        User.stub(:search, []) do
          result = UserManagementServiceSchema.execute(<<~GRAPHQL).to_h
            {
              accountHierarchies(ids: ["first", "second", "first"], as: "#{ACTOR_ID}") {
                id
              }
            }
          GRAPHQL

          assert_nil result["errors"], result.inspect
          assert_equal [["first"], ["second"], ["first"]],
            result.dig("data", "accountHierarchies").map { |hierarchy| hierarchy.map { |account| account.fetch("id") } }
        end
      end
    end

    assert_equal [["first", "second"]], calls
  end

  test "accountWithParents dataloader makes one batch request for multiple fields" do
    calls = []
    batch = lambda do |ids|
      calls << ids
      ids.reverse.map { |id| [Account.new(id: id, name: id.capitalize)] }
    end

    Account.stub(:with_headers, ->(*, &block) { block.call }) do
      Account.stub(:with_parents_batch, batch) do
        result = UserManagementServiceSchema.execute(<<~GRAPHQL).to_h
          {
            first: accountWithParents(id: "first", as: "#{ACTOR_ID}") { id }
            second: accountWithParents(id: "second", as: "#{ACTOR_ID}") { id }
          }
        GRAPHQL

        assert_nil result["errors"], result.inspect
        assert_equal ["first"], result.dig("data", "first").map { |account| account.fetch("id") }
        assert_equal ["second"], result.dig("data", "second").map { |account| account.fetch("id") }
      end
    end

    assert_equal [["first", "second"]], calls
  end
end
