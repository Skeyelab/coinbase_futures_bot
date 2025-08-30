# frozen_string_literal: true

# Custom middleware for enhanced database query monitoring with Sentry
class SentryDatabaseMonitoring
  def initialize
    @slow_query_threshold = (ENV["SENTRY_SLOW_QUERY_THRESHOLD"] || 1000).to_f # milliseconds
  end

  def call(name, started, finished, unique_id, payload)
    return unless payload[:sql]

    duration = (finished - started) * 1000 # Convert to milliseconds
    sql = payload[:sql]

    # Skip internal Rails queries and schema queries
    return if skip_query?(sql)

    # Add breadcrumb for all database queries
    SentryHelper.add_breadcrumb(
      message: "Database query executed",
      category: "db.query",
      level: (duration > @slow_query_threshold) ? "warning" : "debug",
      data: {
        sql: truncate_sql(sql),
        duration_ms: duration.round(2),
        connection_id: payload[:connection_id],
        cached: payload[:cached]
      }
    )

    # Track slow queries as separate events
    if duration > @slow_query_threshold
      track_slow_query(sql, duration, payload)
    end

    # Track queries with errors
    if payload[:exception]
      track_query_error(sql, duration, payload)
    end
  end

  private

  def skip_query?(sql)
    # Skip schema queries, internal Rails queries, and other noise
    sql.match?(/\A\s*(SHOW|DESCRIBE|EXPLAIN|SET|SELECT\s+1|PRAGMA|BEGIN|COMMIT|ROLLBACK)/i) ||
      sql.include?("schema_migrations") ||
      sql.include?("ar_internal_metadata") ||
      sql.include?("good_jobs") ||
      sql.include?("INFORMATION_SCHEMA")
  end

  def truncate_sql(sql)
    # Truncate very long SQL queries for Sentry
    (sql.length > 500) ? "#{sql[0..500]}..." : sql
  end

  def track_slow_query(sql, duration, payload)
    Sentry.with_scope do |scope|
      scope.set_tag("db_performance", "slow_query")
      scope.set_tag("query_type", extract_query_type(sql))
      scope.set_tag("duration_category", categorize_duration(duration))

      scope.set_context("slow_query", {
        sql: truncate_sql(sql),
        duration_ms: duration.round(2),
        threshold_ms: @slow_query_threshold,
        connection_id: payload[:connection_id],
        cached: payload[:cached],
        binds: payload[:binds]&.map(&:value)&.first(10) # Limit bind values
      })

      Sentry.capture_message("Slow database query detected", level: "warning")
    end
  end

  def track_query_error(sql, duration, payload)
    Sentry.with_scope do |scope|
      scope.set_tag("db_error", "query_error")
      scope.set_tag("query_type", extract_query_type(sql))

      scope.set_context("failed_query", {
        sql: truncate_sql(sql),
        duration_ms: duration.round(2),
        connection_id: payload[:connection_id],
        exception: payload[:exception]&.to_s,
        binds: payload[:binds]&.map(&:value)&.first(10)
      })

      Sentry.capture_exception(payload[:exception])
    end
  end

  def extract_query_type(sql)
    # Extract the main SQL operation type
    case sql.strip.upcase
    when /\ASELECT/
      "SELECT"
    when /\AINSERT/
      "INSERT"
    when /\AUPDATE/
      "UPDATE"
    when /\ADELETE/
      "DELETE"
    when /\ACREATE/
      "CREATE"
    when /\ADROP/
      "DROP"
    when /\AALTER/
      "ALTER"
    else
      "OTHER"
    end
  end

  def categorize_duration(duration_ms)
    case duration_ms
    when 0..100
      "fast"
    when 100..500
      "medium"
    when 500..1000
      "slow"
    when 1000..5000
      "very_slow"
    else
      "extremely_slow"
    end
  end
end
