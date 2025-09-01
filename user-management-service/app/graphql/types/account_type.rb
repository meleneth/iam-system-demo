# app/graphql/types/account_type.rb
module Types
  class AccountType < Types::BaseObject
    field :id,   ID,     null: false
    field :name, String, null: false
    field :parent_account_id, ID, null: true

    field :users, [Types::UserType], null: false

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
