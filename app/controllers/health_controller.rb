class HealthController < ApplicationController
  def show
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
      ActiveRecord::Base.connection.execute('SELECT 1')
      true
    rescue StandardError => e
      Rails.logger.error("Database health check failed: #{e.message}")
      false
    end

    # Get GoodJob stats if available
    good_job_stats = begin
      {
        queued: GoodJob::Job.where(finished_at: nil).count,
        running: GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count,
        failed: GoodJob::Job.where.not(error: nil).count
      }
    rescue StandardError => e
      Rails.logger.warn("GoodJob stats unavailable: #{e.message}")
      nil
    end

    health_data = {
      status: connection_ok ? 'healthy' : 'unhealthy',
      timestamp: Time.current.utc.iso8601,
      database: {
        connection_ok: connection_ok,
        pool: pool_stats
      },
      good_job: good_job_stats,
      environment: Rails.env
    }

    if connection_ok
      render json: health_data, status: :ok
    else
      render json: health_data, status: :service_unavailable
    end
  end
end
