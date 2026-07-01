require "test_helper"

class UserAuthorizationModeTest < ActiveSupport::TestCase
  FakeFaradayResponse = Struct.new(:status, :body)
  FakeFaradayRequest = Struct.new(:headers, :body, keyword_init: true)

  test "capabilities-only mode checks batched capabilities instead of can" do
    user = User.new(id: "00000000-0000-0000-0000-000000000001")
    account_ids = [
      "00000000-0000-0000-0000-000000000002",
      "00000000-0000-0000-0000-000000000003"
    ]
    request = nil
    called_url = nil
    old_mode = ENV["AUTHORIZATION_CHECK_MODE"]
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"

    original_post = Faraday.method(:post)
    Faraday.define_singleton_method(:post) do |url, &block|
      called_url = url
      request = FakeFaradayRequest.new(headers: {})
      block.call(request)
      FakeFaradayResponse.new(
        200,
        account_ids.to_h { |account_id| [account_id, ["account.read"]] }.to_json
      )
    end

    assert user.can("Account", "account.read", account_ids)

    assert_equal "#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/Account", called_url
    assert_equal({ "scope_id" => account_ids }, JSON.parse(request.body))
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = old_mode
    Faraday.define_singleton_method(:post) do |*args, **kwargs, &block|
      original_post.call(*args, **kwargs, &block)
    end
  end
end
