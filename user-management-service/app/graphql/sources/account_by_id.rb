# app/graphql/sources/account_by_id.rb
# frozen_string_literal: true

module Sources
  class AccountById < GraphQL::Dataloader::Source
    TRACER = OpenTelemetry.tracer_provider.tracer("sources.account_by_id", "1.0.0")

    # tune these per backend limits
    CHUNK_SIZE      = 2     # “few hundred at a time”
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

          chunks = uniq_ids.each_slice(CHUNK_SIZE).to_a
          span.set_attribute("account.chunks", chunks.size)

          # Collect Account objects from all chunks
          parent_ctx = OpenTelemetry::Context.current

          records = fetch_chunks(chunks, parent_ctx)

          by_id = Array(records).index_by { |acc| acc.id.to_s }
          wanted_ids.map { |id| by_id[id] } # align to original order (nils OK)
        end
      end
    rescue => e
      OpenTelemetry.logger&.warn("AccountById.fetch error: #{e.class}: #{e.message}")
      keys.map { nil }
    end

    private

    def fetch_chunks(chunks, parent_ctx)
      return chunks.flat_map { |slice| fetch_one_chunk(slice, parent_ctx) } if MAX_CONCURRENCY <= 1
      return [] if chunks.empty?

      limit = [chunks.size, MAX_CONCURRENCY].min

      run_in_reactor = -> {
        sem = Async::Semaphore.new(limit)
        tasks = chunks.map do |slice|
          sem.async do
            OpenTelemetry::Context.with_current(parent_ctx) do
              fetch_one_chunk(slice, parent_ctx)
            rescue => e
              OpenTelemetry.logger&.warn("chunk failed: #{e.class}: #{e.message}")
              [] # failed chunk contributes no records
            end
          end
        end
        tasks.flat_map { |t| t.wait }
      }

      # If we're already inside an Async reactor, reuse it; otherwise, start one.
      if (current = Async::Task.current?)
        current.with_timeout(nil) { run_in_reactor.call }
      else
        Async { run_in_reactor.call }.wait
      end
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
            Array(Account.where_async(id: slice_ids).to_a)
          end
        end
      end
    end
  end
end
