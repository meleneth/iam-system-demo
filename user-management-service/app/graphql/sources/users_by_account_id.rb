# app/graphql/sources/users_by_account_id.rb
module Sources
  class UsersByAccountId < BaseSource
    ACCOUNT_ID_FETCH_CHUNK_SIZE = 200

    # keys: [account_id]
    # result: [Array<User>] per account_id
    def initialize(as:, otel_ctx:, tracer:, msp_account_id: nil)
      @as = as
      @otel_ctx = otel_ctx
      @tracer = tracer
      @msp_account_id = msp_account_id
    end

    def fetch(keys)
      OpenTelemetry::Context.with_current(@otel_ctx) do |span|
        trace("User.find(:all, account_id: [#{keys.size} ids])") do
          grouped = Hash.new { |h, k| h[k] = [] }

          with_headers do
            request_headers = { 'pad-user-id' => @as }.tap do |headers|
              headers['pad-msp-account-id'] = @msp_account_id if @msp_account_id.present?
            end
            User.with_headers(request_headers) do
              users = keys.each_slice(ACCOUNT_ID_FETCH_CHUNK_SIZE).flat_map do |account_ids|
                User.search(account_id: account_ids)
              end
              users.each { |u| grouped[u.account_id] << u }
            end
          end

          keys.map { |k| grouped[k] }
        end
      end
    end
  end
end
