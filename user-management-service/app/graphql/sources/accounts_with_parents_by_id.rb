# app/graphql/sources/accounts_with_parents_by_id.rb
module Sources
  class AccountsWithParentsById < BaseSource
    # keys: [account_id]
    # result: [Array<Account>]    (each key returns the array [account, parent, grandparent, ...])
    def initialize(as:, tracer:, otel_ctx:)
      @as = as
      @tracer = tracer
      @otel_ctx = otel_ctx
    end

    def fetch(keys)
      OpenTelemetry::Context.with_current(@otel_ctx) do
        trace("Account.with_parents_batch") do |span|
          span.set_attribute("iam.requested_unique_id_count", keys.map(&:to_s).uniq.size)
          span.set_attribute("iam.downstream_request_count", keys.empty? ? 0 : 1)

          results = []
          with_headers do
            Account.with_headers('pad-user-id' => @as) do
              results = Account.with_parents_batch_ordered(keys)
            end
          end
          results
        end
      end
    end
  end
end
