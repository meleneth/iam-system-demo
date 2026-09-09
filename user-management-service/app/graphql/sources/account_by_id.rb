# app/graphql/sources/account_by_id.rb
# frozen_string_literal: true

module Sources
  class AccountById < GraphQL::Dataloader::Source
    TRACER = OpenTelemetry.tracer_provider.tracer("sources.account_by_id", "1.0.0")

    MAX_CONCURRENCY = 4       # 1 = sequential; increase cautiously

    def initialize(as:, otel_ctx:)
      @as = as
      @otel_ctx = otel_ctx
    end

    def fetch(keys)
      OpenTelemetry::Context.with_current(@otel_ctx) do |span|
        TRACER.in_span("AccountById.fetch") do |span|
          wanted_ids = keys.map(&:to_s)
          uniq_ids   = wanted_ids.uniq
          span.set_attribute("account.requested", wanted_ids.size)
          span.set_attribute("account.unique", uniq_ids.size)

          chunks = uniq_ids.each_slice(IamDemo.batch_size).to_a
          span.set_attribute("account.chunks", chunks.size)
          span.set_attribute("iam.batch_size", IamDemo.batch_size)

          # Collect Account objects from all chunks
          parent_ctx = OpenTelemetry::Context.current

          records = fetch_chunks(chunks, parent_ctx)

          by_id = Array(records).index_by { |acc| acc.id.to_s }
          unless records.map { |account| account.id.to_s }.sort == uniq_ids.sort
            raise GraphQL::ExecutionError, "Account Service returned an incomplete or unexpected account set"
          end
          wanted_ids.map { |id| by_id.fetch(id) }
        end
      end

    end

    private

    # Fetch all chunks with bounded parallelism
    def fetch_chunks(chunks, parent_ctx)
      return chunks.flat_map { |slice| fetch_one_chunk(slice, parent_ctx) } if MAX_CONCURRENCY <= 1

      # Simple worker pool using Async or threads; prefer threads to avoid clashing with AR connection state
      # Threads are fine here because we isolate per-request headers and do not mutate global state.
      queue   = Queue.new
      chunks.each { |c| queue << c }
      workers = [chunks.size, MAX_CONCURRENCY].min
      mutex   = Mutex.new
      results = []
      errors = Queue.new

      threads = Array.new(workers) do |i|
        Thread.new do
          OpenTelemetry::Context.with_current(parent_ctx) do
            while (slice = queue.pop(true) rescue nil)
              begin
                recs = fetch_one_chunk(slice, parent_ctx)
                mutex.synchronize { results.concat(recs) }
              rescue => e
                errors << e
              end
            end
          end
        end
      end

      threads.each(&:join)
      raise errors.pop unless errors.empty?

      results
    end

    # POST keeps large configured batches out of the request URL.
    def fetch_one_chunk(slice_ids, parent_ctx)
      OpenTelemetry::Context.with_current(parent_ctx) do
        TRACER.in_span("AccountById.fetch_chunk") do |span|
          span.set_attribute("chunk.size", slice_ids.size)
          headers_override = {"pad-user-id" => @as}
          OpenTelemetry.propagation.inject(headers_override)
          Account.with_headers(headers_override) do
            Array(Account.search(id: slice_ids))
          end
        end
      end
    end
  end
end
