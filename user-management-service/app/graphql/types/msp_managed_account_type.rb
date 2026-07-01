# frozen_string_literal: true

module Types
  class MspManagedAccountType < Types::BaseObject
    field :id, ID, null: false
    field :users, [Types::UserType], null: false

    def id
      object.fetch(:id)
    end

    def users
      ctx = context
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      ctx.dataloader
         .with(Sources::UsersByAccountId, as: ctx[:as], tracer: ctx[:tracer], otel_ctx: otel_ctx)
         .load(object.fetch(:id))
    end
  end
end
