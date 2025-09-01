# app/graphql/types/user_type.rb
module Types
  class UserType < Types::BaseObject
    field :id,        ID,     null: false
    field :account_id, ID,    null: false
    field :email,      String, null: false

    field :groups, [Types::GroupType], null: false

    def groups
      ctx = context
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      ctx.dataloader
         .with(Sources::GroupsByUserId, as: ctx[:as], tracer: ctx[:tracer], otel_ctx: otel_ctx)
         .load(object.id)
    end
  end
end
