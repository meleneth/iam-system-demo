# app/graphql/types/account_type.rb
module Types
  class AccountType < Types::BaseObject
    field :id,   ID,     null: false
    field :name, String, null: false
    field :parent_account_id, ID, null: true

    field :users, [Types::UserType], null: false
    field :users_count, Integer, null: false
    field :groups_count, Integer, null: false

    def users_count
      ctx = context
      dataloader
        .with(Sources::UsersCountByAccount, as: ctx[:as], tracer: ctx[:tracer], otel_ctx: ctx[:otel_ctx])
        .load(object.id)
    end

    def groups_count
      ctx = context
      dataloader
        .with(Sources::GroupsCountByAccount, as: ctx[:as], tracer: ctx[:tracer], otel_ctx: ctx[:otel_ctx])
        .load(object.id)
    end

    def users
      ctx = context
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      ctx.dataloader
         .with(Sources::UsersByAccountId, as: ctx[:as], tracer: ctx[:tracer], otel_ctx: ctx[:otel_ctx])
         .load(object.id)
    end
  end
end
