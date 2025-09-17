class HealthController < ApplicationController
  def show
    # Add Sentry breadcrumb for health check
    SentryHelper.add_breadcrumb(
      message: "Health check requested",
      category: "health_check",
      level: "info",
      data: {controller: "health", action: "show"}
    )

    # Get database connection pool information
    pool = ActiveRecord::Base.connection_pool
    pool_stats = {
      size: pool.size,
      connections: pool.connections.size,
      in_use: pool.connections.count(&:in_use?),
      available: pool.size - pool.connections.count(&:in_use?),
      waiting: pool.num_waiting_in_queue
    }

    # Check if we can get a connection (basic connectivity test)
    connection_ok = begin
      ActiveRecord::Base.connection.execute("SELECT 1")
      true
    rescue => e
      Rails.logger.error("Database health check failed: #{e.message}")

      # Track database connectivity issues
      Sentry.with_scope do |scope|
        scope.set_tag("health_check_type", "database")
        scope.set_tag("error_type", "database_connectivity_error")
        scope.set_context("database_health", pool_stats)

        Sentry.capture_exception(e)
      end

      false
    end

    # Get GoodJob stats if available
    good_job_stats = begin
      stats = {
        queued: GoodJob::Job.where(finished_at: nil).count,
        running: GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count,
        failed: GoodJob::Job.where.not(error: nil).count
      }

      # Track job queue health
      if stats[:failed] > 10
        Sentry.with_scope do |scope|
          scope.set_tag("health_check_type", "job_queue")
          scope.set_tag("error_type", "high_failed_job_count")
          scope.set_context("job_stats", stats)

          Sentry.capture_message("High number of failed jobs detected", level: "warning")
        end
      end

      stats
    rescue => e
      Rails.logger.warn("GoodJob stats unavailable: #{e.message}")

      # Track GoodJob stats failures
      Sentry.with_scope do |scope|
        scope.set_tag("health_check_type", "job_queue")
        scope.set_tag("error_type", "job_stats_error")

        Sentry.capture_exception(e)
      end

      nil
    end

    # Get position breakdown
    positions_data = begin
      {
        day_trading: Position.open.day_trading.count,
        swing_trading: Position.open.swing_trading.count,
        total: Position.open.count
      }
    rescue => e
      Rails.logger.warn("Failed to get position counts: #{e.message}")
      {day_trading: 0, swing_trading: 0, total: 0}
    end

    # Get cached health check data if available
    cached_health = Rails.cache.read("last_health_check")
    
    health_data = {
      status: connection_ok ? "healthy" : "unhealthy",
      timestamp: Time.current.utc.iso8601,
      database: {
        connection_ok: connection_ok,
        pool: pool_stats
      },
      positions: positions_data,
      good_job: good_job_stats,
      environment: Rails.env,
      last_health_check: cached_health ? cached_health[:timestamp] : nil
    }
    
    # Include detailed health data if available from cache
    if cached_health && cached_health[:data]
      health_data[:detailed_health] = cached_health[:data]
    end

    if connection_ok
      render json: health_data, status: :ok
    else
      render json: health_data, status: :service_unavailable
    end
  end
end
