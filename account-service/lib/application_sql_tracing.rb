# frozen_string_literal: true

require "active_support/notifications"

# Instrument application SQL at the execution notification, where Rails identifies
# schema introspection and query-cache hits. Do not instrument PG separately.
module ApplicationSqlTracing
  APPLICATION_COMMAND = /\A\s*(SELECT|INSERT|UPDATE|DELETE|WITH)\b/i
  CATALOG_QUERY = /\b(?:pg_catalog|information_schema|pg_attribute|pg_class|pg_type|pg_namespace|pg_index|pg_constraint|pg_collation|pg_am)\b/i

  def self.application_query?(payload)
    !payload[:cached] && !%w[SCHEMA TRANSACTION].include?(payload[:name]) &&
      APPLICATION_COMMAND.match?(payload[:sql].to_s) && !CATALOG_QUERY.match?(payload[:sql].to_s)
  end

  def self.install
    ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, started, finished, _id, payload|
      next unless application_query?(payload) && OpenTelemetry::Trace.current_span.recording?

      sql = payload.fetch(:sql)
      connection = payload[:connection]
      database = connection&.pool&.db_config&.database.to_s
      span = OpenTelemetry.tracer_provider.tracer("iam.application_sql").start_span(
        "SQL #{payload[:name] || sql[APPLICATION_COMMAND, 1].upcase}",
        kind: :client, start_timestamp: started,
        attributes: { "db.system" => "postgresql", "db.name" => database,
          "db.statement" => sql, "db.query.name" => payload[:name].to_s }
      )
      if (error = payload[:exception_object])
        span.record_exception(error)
        span.status = OpenTelemetry::Trace::Status.error(error.message)
      end
      span.finish(end_timestamp: finished)
    end
  end
end
