# app/graphql/sources/users_by_account_id.rb
module Sources
  class UsersByAccountId < BaseSource
    # keys: [account_id]
    # result: [Array<User>] per account_id
    def initialize(as:, otel_ctx:, tracer:)
      @as = as
      @otel_ctx = otel_ctx
      @tracer = tracer
    end

    def fetch(keys)
      OpenTelemetry::Context.with_current(@otel_ctx) do |span|
        trace("User.find(:all, account_id: [#{keys.size} ids])") do
          grouped = Hash.new { |h, k| h[k] = [] }

          with_headers do
            User.with_headers('pad-user-id' => @as) do
              users = keys.empty? ? [] : User.find(:all, params: { account_id: keys })
              users.each { |u| grouped[u.account_id] << u }
            end
          end

          keys.map { |k| grouped[k] }
        end
      end
    end
  end
end
