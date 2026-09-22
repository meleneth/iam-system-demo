# app/graphql/sources/base_source.rb
module Sources
  class BaseSource < GraphQL::Dataloader::Source
    def initialize(as:, tracer:)
      @as     = as
      @tracer = tracer
    end

    private

    def trace(span_name, &block)
      @tracer.in_span(span_name, &block)
    end
  end
end
