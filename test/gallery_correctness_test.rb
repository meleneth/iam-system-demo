require "minitest/autorun"
require_relative "../scripts/gallery_correctness"

class GalleryCorrectnessTest < Minitest::Test
  def setup
    @fixture = {"name" => "example", "msp" => true, "account_count" => 2}
    account = GalleryCorrectness.uuid("example/customer/account/1")
    @page = {"loading" => false, "totalCount" => 1, "loadedCount" => 1, "continuance" => nil,
      "accounts" => [{"id" => account, "users" => [{"id" => GalleryCorrectness.uuid("example/customer/user/1"),
        "accountId" => account, "groups" => [{"id" => GalleryCorrectness.uuid("example/group/#{account}/Users"), "name" => "Users"}]}]}]}
  end

  def validate
    GalleryCorrectness.validate(JSON.generate("data" => {"mspUserManagement" => @page}), fixture: @fixture, batch_size: 200, graphql: true)
  end

  def test_valid_exact_identities
    assert validate.fetch("passed")
  end

  def test_same_count_foreign_account_is_rejected
    @page["accounts"][0]["id"] = "foreign-account"
    assert_raises(RuntimeError) { validate }
  end

  def test_foreign_group_is_rejected
    @page["accounts"][0]["users"][0]["groups"][0]["id"] = "foreign-group"
    assert_raises(RuntimeError) { validate }
  end

  def test_wrong_total_is_rejected
    @page["totalCount"] = 2
    assert_raises(RuntimeError) { validate }
  end
end
