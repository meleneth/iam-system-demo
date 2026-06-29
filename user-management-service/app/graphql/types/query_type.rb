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
      description "Private demo view for MSP reflected user-management grants."
      argument :msp_account_id, ID, required: true
      argument :as, ID, required: true
      argument :continuance, String, required: false
    end

    def organization(id:, as:)
      context[:as] = as
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      Organization.with_headers("pad-user-id" => as) do
        Organization.find(id)
      end
    end

    def account(id:, as:)
      context[:as] = as
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx

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

    def accounts(ids:, as:)
      context[:as] = as
      context[:tracer] = TRACER
      otel_ctx = context[:otel_ctx] || OpenTelemetry::Context.current
      context[:otel_ctx] = otel_ctx
      dataloader.with(Sources::AccountById, as: as, otel_ctx: otel_ctx)
        .load_all(ids)
        .then { |records| records.compact }
    end

    def msp_user_management(msp_account_id:, as:, continuance: nil)
      context[:as] = as
      context[:msp_account_id] = msp_account_id
      context[:tracer] = TRACER
      context[:otel_ctx] ||= OpenTelemetry::Context.current

      status = MspReflectedUserGrant.check(user_id: as, msp_account_id: msp_account_id, account_ids: [])
      raise GraphQL::ExecutionError, status[:error] if status[:status] == "failed"
      return loading_payload(status) if status.fetch(:loading)

      page = MspManagedAccount.page(msp_account_id, continuance: continuance)
      account_ids = page.fetch("managed_account_ids").map(&:to_s)
      check = MspReflectedUserGrant.check(user_id: as, msp_account_id: msp_account_id, account_ids: account_ids)
      raise GraphQL::ExecutionError, check[:error] if check[:status] == "failed"
      return loading_payload(check) if check.fetch(:loading)

      authorized_ids = check.fetch(:authorized_account_ids)
      total_count = page.fetch("total_count", check.fetch(:total_count)).to_i
      {
        loading: false,
        loaded_count: check.fetch(:loaded_count),
        total_count: total_count,
        continuance: page["continuance"],
        message: "MSP user-management access ready. Loaded #{check.fetch(:loaded_count)} of #{total_count} accounts.",
        accounts: authorized_ids.map { |account_id| { id: account_id } }
      }
    end

    def loading_payload(status)
      loaded = status.fetch(:loaded_count)
      total = status.fetch(:total_count)
      {
        loading: true,
        loaded_count: loaded,
        total_count: total,
        continuance: nil,
        message: "Preparing MSP user-management access. Loaded #{loaded} of #{total} accounts.",
        accounts: []
      }
    end
  end
end
