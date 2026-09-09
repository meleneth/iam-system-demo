require "test_helper"
require "minitest/mock"

class RetrievalFailuresTest < ActiveSupport::TestCase
  test "a failed concurrent account chunk fails the complete load" do
    source = account_source
    keys = (1..(IamDemo.batch_size + 1)).map(&:to_s)
    fetch = lambda do |ids, _context|
      raise ActiveResource::ServerError.new(Net::HTTPInternalServerError.new("1.1", "500", "failed")) if ids.include?(keys.last)
      ids.map { |id| Account.new(id: id) }
    end
    source.stub(:fetch_one_chunk, fetch) do
      assert_raises(ActiveResource::ServerError) { source.fetch(keys) }
    end
  end

  test "account source rejects missing duplicated or unexpected records" do
    [["a"], ["a", "a"], ["a", "other"]].each do |returned_ids|
      source = account_source
      source.stub(:fetch_one_chunk, ->(*) { returned_ids.map { |id| Account.new(id: id) } }) do
        assert_raises(GraphQL::ExecutionError) { source.fetch(["a", "b"]) }
      end
    end
  end

  test "account source preserves ordering and duplicate requested keys" do
    source = account_source
    source.stub(:fetch_one_chunk, ->(*) { [Account.new(id: "b"), Account.new(id: "a")] }) do
      assert_equal %w[b a b], source.fetch(%w[b a b]).map(&:id)
    end
  end

  test "GraphQL surfaces both missing and denied account reads as errors" do
    [Net::HTTPNotFound.new("1.1", "404", "missing"), Net::HTTPForbidden.new("1.1", "403", "denied")].each do |response|
      exception = response.code == "404" ? ActiveResource::ResourceNotFound : ActiveResource::ForbiddenAccess
      Account.stub(:find, ->(*) { raise exception.new(response) }) do
        result = UserManagementServiceSchema.execute('{ account(id: "a", as: "actor") { id } }').to_h
        assert result["errors"].present?, result.inspect
      end
    end
  end

  test "group source rejects a membership whose group was omitted" do
    source = Sources::GroupsByUserId.new(as: "actor", otel_ctx: OpenTelemetry::Context.current,
      tracer: OpenTelemetry.tracer_provider.tracer("test"))
    GroupUser.stub(:search, [GroupUser.new(user_id: "user", group_id: "missing")]) do
      Group.stub(:search, []) do
        assert_raises(GraphQL::ExecutionError) { source.fetch(["user"]) }
      end
    end
  end

  test "organization GraphQL fields reject incomplete account collections" do
    Organization.stub(:find, Organization.new(id: "org")) do
      links = %w[a b].map { |id| OrganizationAccount.new(account_id: id) }
      OrganizationAccount.stub(:find, links) do
        Account.stub(:search, [Account.new(id: "a")]) do
          result = UserManagementServiceSchema.execute('{ organization(id: "org", as: "actor") { accounts { id } } }').to_h
          assert result["errors"].present?, result.inspect
        end
      end
    end
  end

  private

  def account_source
    Sources::AccountById.new(as: "actor", otel_ctx: OpenTelemetry::Context.current)
  end
end
