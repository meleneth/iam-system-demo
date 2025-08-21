# app/graphql/sources/account_by_id.rb
# frozen_string_literal: true

module Sources
  class AccountById < GraphQL::Dataloader::Source
    TRACER = OpenTelemetry.tracer_provider.tracer("sources.account_by_id", "1.0.0")

    # tune these per backend limits
    CHUNK_SIZE      = 2     # “few hundred at a time”
    MAX_CONCURRENCY = 4       # 1 = sequential; increase cautiously

    def initialize(as:)
      @as = as
    end

    def fetch(keys)
      TRACER.in_span("AccountById.fetch") do |span|
        wanted_ids = keys.map(&:to_s)
        uniq_ids   = wanted_ids.uniq
        span.set_attribute("account.requested", wanted_ids.size)
        span.set_attribute("account.unique", uniq_ids.size)

        chunks = uniq_ids.each_slice(CHUNK_SIZE).to_a
        span.set_attribute("account.chunks", chunks.size)

        # Collect Account objects from all chunks
        parent_ctx = OpenTelemetry::Context.current

        records = fetch_chunks(chunks, parent_ctx)

        by_id = Array(records).index_by { |acc| acc.id.to_s }
        wanted_ids.map { |id| by_id[id] } # align to original order (nils OK)
      end
    rescue => e
      OpenTelemetry.logger&.warn("AccountById.fetch error: #{e.class}: #{e.message}")
      keys.map { nil }
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

      threads = Array.new(workers) do |i|
        Thread.new do
          OpenTelemetry::Context.with_current(parent_ctx) do
            while (slice = queue.pop(true) rescue nil)
              begin
                recs = fetch_one_chunk(slice, parent_ctx)
                mutex.synchronize { results.concat(recs) }
              rescue => e
                OpenTelemetry.logger&.warn("chunk failed: #{e.class}: #{e.message}")
                # continue; failed chunk contributes no records
              end
            end
          end
        end
      end

      threads.each(&:join)
      results
    end

    # Fetch a single chunk via the batch endpoint; fall back to where(id: [...])
    def fetch_one_chunk(slice_ids, parent_ctx)
      OpenTelemetry::Context.with_current(parent_ctx) do
        TRACER.in_span("AccountById.fetch_chunk") do |span|
          span.set_attribute("chunk.size", slice_ids.size)
          raw = nil
          headers_override = {"pad-user-id" => @as}
          OpenTelemetry.propagation.inject(headers_override)
          Account.with_headers(headers_override) do
            Array(Account.where(id: slice_ids).to_a)
          end
        end
      end
    end
  end
end
