# app/graphql/sources/users_count_by_account.rb
# frozen_string_literal: true
module Sources
  class UsersCountByAccount < GraphQL::Dataloader::Source
    def initialize(as:, tracer:, otel_ctx:)
      @as = as
      @tracer = tracer
      @otel_ctx = otel_ctx
    end

    def fetch(account_ids)
      map = User.users_count(account_ids)
      account_ids.map { |id| (map[id.to_sym] || 0).to_i }
    end
  end
end
