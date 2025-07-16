module Mel
  module Filterable
    extend ActiveSupport::Concern

    class_methods do
      def filterable_fields(*fields)
        @filterable_fields ||= []
        @filterable_fields.concat(fields.map(&:to_s))
      end

      def allowed_filters
        @filterable_fields || []
      end
    end
  end
end
