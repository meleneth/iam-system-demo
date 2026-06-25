# frozen_string_literal: true

module Types
  class MspManagedUserType < Types::BaseObject
    field :id, ID, null: false
    field :account_id, ID, null: false
    field :email, String, null: false
    field :groups, [Types::GroupType], null: false

    def groups
      ctx = context
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      ctx.dataloader
         .with(Sources::GroupsByUserId, as: ctx[:as], msp_account_id: ctx[:msp_account_id], tracer: ctx[:tracer], otel_ctx: otel_ctx)
         .load(object.id)
    end
  end
end
