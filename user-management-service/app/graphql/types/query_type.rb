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

    field :accounts, [Types::AccountType], null: false do
      description "Fetch many accounts by UUID, authorized as the given user UUID"
      argument :ids, [ID], required: true
      argument :as,  ID,   required: true
    end


    field :organization, Types::OrganizationType, null: true do
      argument :id, ID, required: true
      argument :as, ID, required: true
    end

    field :msp_user_management, Types::MspUserManagementType, null: false do
      description "Demo view for org-level MSP user-management access."
      argument :msp_account_id, ID, required: true
      argument :as, ID, required: true
      argument :continuance, String, required: false
    end

    def organization(id:, as:)
      context.scoped_set!(:as, as)
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      AuthorizationContext.as_requesting_user(user_id: as) do
        Organization.find(id)
      end
    end

    def account(id:, as:)
      context.scoped_set!(:as, as)
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx

      # Pass caller identity to downstream via header you already use
      AuthorizationContext.as_requesting_user(user_id: as) do
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
    end

    def accounts(ids:, as:)
      context.scoped_set!(:as, as)
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      dataloader.with(Sources::AccountById, as: as, otel_ctx: otel_ctx)
        .load_all(ids)
    end

    def msp_user_management(msp_account_id:, as:, continuance: nil)
      context.scoped_set!(:as, as)
      context[:tracer] = TRACER
      context[:otel_ctx] ||= OpenTelemetry::Context.current

      page = AuthorizationContext.as_requesting_user(user_id: as, account_id: msp_account_id) do
        MspManagedOrganization.page(msp_account_id, user_id: as, continuance: continuance)
      end
      msp_organization_id = page["msp_organization_id"]
      raise GraphQL::ExecutionError, "Unknown MSP account #{msp_account_id}" if msp_organization_id.blank?

      total_count = page.fetch("total_count").to_i
      account_ids = page.fetch("managed_account_ids").map(&:to_s)
      loaded_count = [continuance.to_i + account_ids.length, total_count].min
      {
        loading: false,
        loaded_count: loaded_count,
        total_count: total_count,
        continuance: page["continuance"],
        message: "MSP user-management access ready. Loaded #{loaded_count} of #{total_count} accounts.",
        accounts: account_ids.map { |account_id| { id: account_id } }
      }
    end

  end
end
