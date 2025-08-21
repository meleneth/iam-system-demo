# frozen_string_literal: true
# app/graphql/types/query_type.rb
module Types
  class QueryType < BaseObject
    TRACER = OpenTelemetry.tracer_provider.tracer('GraphQL::Query', '1.0.0')

    field :account, Types::AccountType, null: true do
      description "Fetch a single account by UUID, authorized as the given user UUID"
      argument :id, ID, required: true
      argument :as, ID, required: true # user id to authorize-as
    end

    field :account_with_parents, resolver: Resolvers::AccountWithParentsResolver
    field :account_hierarchies, resolver: Resolvers::AccountHierarchiesResolver

    field :organization, Types::OrganizationType, null: true do
      argument :id, ID, required: true
      argument :as, ID, required: true
    end

    def organization(id:, as:)
      context[:as] = as
      context[:tracer] = TRACER
      Organization.with_headers("pad-user-id" => as) do
        Organization.find(id)
      end
    end

    def account(id:, as:)
      context[:tracer] = TRACER
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
