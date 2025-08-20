# app/graphql/sources/base_source.rb
module Sources
  class BaseSource < GraphQL::Dataloader::Source
    def initialize(as:, tracer:)
      @as     = as
      @tracer = tracer
    end

    private

    def with_headers(&block)
      # All your ActiveResource models honor .with_headers
      OpenTelemetry::Context.with_current(OpenTelemetry::Context.current) do
        yield
      end
    end

    def trace(span_name, &block)
      @tracer.in_span(span_name, &block)
    end
  end
end
