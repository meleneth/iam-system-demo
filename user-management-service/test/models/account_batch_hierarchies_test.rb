require "test_helper"
require "minitest/mock"

class AccountBatchHierarchiesTest < ActiveSupport::TestCase
  test "maps a reordered batch response back to requested order and duplicates" do
    child = Account.new(id: "child", parent_account_id: "parent")
    parent = Account.new(id: "parent")
    sibling = Account.new(id: "sibling")

    Account.stub(:with_parents_batch, [[sibling], [child, parent]]) do
      result = Account.with_parents_batch_ordered(["child", "sibling", "child"])

      assert_equal [["child", "parent"], ["sibling"], ["child", "parent"]],
        result.map { |hierarchy| hierarchy.map(&:id) }
    end
  end

  test "returns an empty hierarchy for a missing or invalid response" do
    wrong_target = Account.new(id: "wrong-target")

    Account.stub(:with_parents_batch, [[wrong_target]]) do
      assert_equal [[]], Account.with_parents_batch_ordered(["missing"])
    end
  end

  test "does not call the account service for empty input" do
    Account.stub(:with_parents_batch, ->(*) { flunk "unexpected downstream request" }) do
      assert_equal [], Account.with_parents_batch_ordered([])
    end
  end
end
