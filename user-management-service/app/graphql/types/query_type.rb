# frozen_string_literal: true
# app/graphql/types/query_type.rb
module Types
  class QueryType < BaseObject
    field :account, Types::AccountType, null: true do
      description "Fetch a single account by UUID, authorized as the given user UUID"
      argument :id, ID, required: true
      argument :as, ID, required: true # user id to authorize-as
    end

    def account(id:, as:)
      # Pass caller identity to downstream via header you already use
      Account.with_headers("pad-user-id" => as) do
        # You likely already have Account.find(id) on ActiveResource
        # If your service expects ?id= or a path, adjust accordingly.
        record = Account.find(id)

        # If you prefer to double-check permissions locally, do it here.
        # For now we rely on the downstream service to 403/404 as needed.
        OpenTelemetry::Trace.current_span&.add_event(
          "GraphQL Query: account",
          attributes: { "account.id" => id, "as.user_id" => as }
        )

        record
      end
    rescue ActiveResource::ForbiddenAccess
      # Option A (quiet): return nil
      nil
      # Option B (loud): raise GraphQL::ExecutionError, "Not authorized"
    end
  end
end
