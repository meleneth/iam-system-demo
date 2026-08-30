require "test_helper"
require "minitest/mock"

class AccountHierarchyBatchingTest < ActiveSupport::TestCase
  ACTOR_ID = "actor-1"

  FakeSpan = Struct.new(:attributes) do
    def set_attribute(name, value)
      attributes[name] = value
    end
  end

  class FakeTracer
    attr_reader :span_name, :span

    def initialize
      @span = FakeSpan.new({})
    end

    def in_span(name)
      @span_name = name
      yield span
    end
  end

  test "accountHierarchies makes one batch request and restores requested order" do
    calls = []
    headers = []
    user_headers = []
    batch = lambda do |ids|
      calls << ids
      [
        [Account.new(id: "second", name: "Second")],
        [Account.new(id: "first", name: "First")]
      ]
    end

    Account.stub(:with_headers, ->(value, &block) { headers << value; block.call }) do
      Account.stub(:with_parents_batch, batch) do
        User.stub(:with_headers, ->(value, &block) { user_headers << value; block.call }) do
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
    end

    assert_equal [["first", "second"]], calls
    assert_equal [{ "pad-user-id" => ACTOR_ID }], headers
    assert_equal [{ "pad-user-id" => ACTOR_ID }], user_headers
  end

  test "accountWithParents dataloader makes one batch request for multiple fields" do
    calls = []
    headers = []
    batch = lambda do |ids|
      calls << ids
      ids.reverse.map { |id| [Account.new(id: id, name: id.capitalize)] }
    end

    Account.stub(:with_headers, ->(value, &block) { headers << value; block.call }) do
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
    assert_equal [{ "pad-user-id" => ACTOR_ID }], headers
  end

  test "both GraphQL hierarchy paths propagate Account Service failure" do
    calls = 0
    failure = lambda do |*|
      calls += 1
      raise ActiveResource::ServerError.new(
        Net::HTTPInternalServerError.new("1.1", "500", "Account Service failure")
      )
    end

    Account.stub(:with_headers, ->(*, &block) { block.call }) do
      Account.stub(:with_parents_batch, failure) do
        assert_raises(ActiveResource::ServerError) do
          UserManagementServiceSchema.execute(<<~GRAPHQL).to_h
            { accountHierarchies(ids: ["first", "second"], as: "#{ACTOR_ID}") { id } }
          GRAPHQL
        end
        assert_raises(ActiveResource::ServerError) do
          UserManagementServiceSchema.execute(<<~GRAPHQL).to_h
            { accountWithParents(id: "third", as: "#{ACTOR_ID}") { id } }
          GRAPHQL
        end
      end
    end

    assert_equal 2, calls
  end

  test "dataloader source restores trace context and reports one downstream request" do
    tracer = FakeTracer.new
    otel_context = Object.new
    restored_contexts = []
    headers = []
    context_wrapper = lambda do |context, &block|
      restored_contexts << context
      block.call
    end
    source = Sources::AccountsWithParentsById.new(as: ACTOR_ID, tracer: tracer, otel_ctx: otel_context)

    OpenTelemetry::Context.stub(:with_current, context_wrapper) do
      Account.stub(:with_headers, ->(value, &block) { headers << value; block.call }) do
        Account.stub(
          :with_parents_batch_ordered,
          [[Account.new(id: "first")], [Account.new(id: "second")], [Account.new(id: "first")]]
        ) do
          result = source.fetch(["first", "second", "first"])

          assert_equal 3, result.length
        end
      end
    end

    assert_same otel_context, restored_contexts.first
    assert_equal "Account.with_parents_batch", tracer.span_name
    assert_equal 2, tracer.span.attributes.fetch("iam.requested_unique_id_count")
    assert_equal 1, tracer.span.attributes.fetch("iam.downstream_request_count")
    assert_equal [{ "pad-user-id" => ACTOR_ID }], headers
  end
end
