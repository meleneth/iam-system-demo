# app/graphql/sources/account_by_id.rb
module Sources
  class AccountById < GraphQL::Dataloader::Source
    TRACER = OpenTelemetry.tracer_provider.tracer('sources.account_by_id', '1.0.0')

    def initialize(as:)
      @as = as
    end

    # keys is an array of account IDs to fetch
    def fetch(keys)
      TRACER.in_span("AccountById.fetch") do |span|
        span.set_attribute("account.count", keys.size)

        # IMPORTANT: array params — many libs expect repeated keys: account_ids[]=a&account_ids[]=b
        params = { 'account_ids[]' => keys }

        raw = nil
        data = []
        Account.with_headers('pad-user-id' => @as) do
          # Prefer a batch endpoint if you have it:
          # raw = Account.connection.get("/accounts.json") { |req|
          #   req.params.update(params)
          #   req.headers.update(Account.headers) # keep oth headers
          # }
          # data = ActiveSupport::JSON.decode(raw.body)

          data = Account.find(:all, params: {id: keys}) # or Account.find(:all, params: params)

          # `data` must be an array of Account instances indexed by ID
          # If it's just hashes, re-inflate:
          # accounts = data.map { |attrs| Account.new(attrs) }
        end

        # Build a lookup table by id (stringify to be safe)
        by_id = Array(data).index_by { |acc| acc.id.to_s }

        # Return results aligned with `keys` in order
        keys.map { |k| by_id[k.to_s] }
      end
    rescue => e
      # GraphQL::Dataloader expects an array the same length as `keys`
      keys.map { nil }
    end
  end
end
