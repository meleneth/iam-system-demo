# app/graphql/sources/users_count_by_account.rb
# frozen_string_literal: true
module Sources
  class GroupsCountByAccount < GraphQL::Dataloader::Source
    def initialize(as:, tracer:, otel_ctx:)
      @as = as
      @tracer = tracer
      @otel_ctx = otel_ctx
    end

    def fetch(account_ids)
      map = OpenTelemetry::Context.with_current(@otel_ctx) do
        Group.with_headers("pad-user-id" => @as) do
          account_ids.each_slice(IamDemo.batch_size).each_with_object({}) do |ids, counts|
            counts.merge!(Group.groups_count(ids))
          end
        end
      end
      account_ids.map { |id| (map[id.to_sym] || 0).to_i }
    end
  end
end
