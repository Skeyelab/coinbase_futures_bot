# frozen_string_literal: true

# Service for tracking performance metrics and bottlenecks in Sentry
class SentryPerformanceService
  class << self
    # Track external API call performance
    def track_external_api_performance(service, endpoint, duration_ms, success = true)
      return unless enabled?

      # Categorize performance
      performance_tier = categorize_api_performance(duration_ms)

      SentryHelper.add_breadcrumb(
        message: "External API call performance",
        category: "api.performance",
        level: (performance_tier == "slow") ? "warning" : "info",
        data: {
          service: service,
          endpoint: endpoint,
          duration_ms: duration_ms.round(2),
          performance_tier: performance_tier,
          success: success
        }
      )

      # Track slow API calls as separate events
      if performance_tier == "slow"
        Sentry.with_scope do |scope|
          scope.set_tag("performance", "slow_external_api")
          scope.set_tag("service", service)
          scope.set_tag("endpoint", endpoint)

          scope.set_context("slow_api_call", {
            service: service,
            endpoint: endpoint,
            duration_ms: duration_ms.round(2),
            threshold_ms: slow_api_threshold,
            success: success
          })

          Sentry.capture_message("Slow external API call detected", level: "warning")
        end
      end
    end

    # Track trading operation performance
    def track_trading_performance(operation, duration_ms, context = {})
      return unless enabled?

      performance_tier = categorize_trading_performance(duration_ms)

      SentryHelper.add_breadcrumb(
        message: "Trading operation performance",
        category: "trading.performance",
        level: (performance_tier == "slow") ? "warning" : "info",
        data: {
          operation: operation,
          duration_ms: duration_ms.round(2),
          performance_tier: performance_tier
        }.merge(context)
      )

      # Track slow trading operations
      if performance_tier == "slow"
        Sentry.with_scope do |scope|
          scope.set_tag("performance", "slow_trading_operation")
          scope.set_tag("trading_operation", operation)
          scope.set_tag("critical", "true")

          scope.set_context("slow_trading_operation", {
            operation: operation,
            duration_ms: duration_ms.round(2),
            threshold_ms: slow_trading_threshold,
            context: context
          })

          Sentry.capture_message("Slow trading operation detected", level: "warning")
        end
      end
    end

    # Track memory usage spikes
    def track_memory_usage
      return unless enabled?

      memory_mb = get_memory_usage_mb
      return unless memory_mb

      memory_tier = categorize_memory_usage(memory_mb)

      SentryHelper.add_breadcrumb(
        message: "Memory usage check",
        category: "performance.memory",
        level: (memory_tier == "high") ? "warning" : "info",
        data: {
          memory_mb: memory_mb.round(2),
          memory_tier: memory_tier
        }
      )

      # Track high memory usage
      if memory_tier == "high"
        Sentry.with_scope do |scope|
          scope.set_tag("performance", "high_memory_usage")
          scope.set_tag("memory_tier", memory_tier)

          scope.set_context("memory_usage", {
            memory_mb: memory_mb.round(2),
            threshold_mb: high_memory_threshold,
            timestamp: Time.current.utc.iso8601
          })

          Sentry.capture_message("High memory usage detected", level: "warning")
        end
      end
    end

    # Track job queue performance
    def track_job_queue_performance
      return unless enabled?

      begin
        queue_stats = {
          total_queued: GoodJob::Job.where(finished_at: nil).count,
          total_running: GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count,
          total_failed: GoodJob::Job.where.not(error: nil).count,
          critical_queued: GoodJob::Job.where(finished_at: nil, queue_name: "critical").count,
          default_queued: GoodJob::Job.where(finished_at: nil, queue_name: "default").count
        }

        # Calculate queue health score
        queue_health = calculate_queue_health(queue_stats)

        SentryHelper.add_breadcrumb(
          message: "Job queue performance check",
          category: "performance.queue",
          level: (queue_health < 0.7) ? "warning" : "info",
          data: queue_stats.merge(
            queue_health_score: queue_health.round(2)
          )
        )

        # Track queue performance issues
        if queue_health < 0.7
          Sentry.with_scope do |scope|
            scope.set_tag("performance", "poor_queue_health")
            scope.set_tag("queue_health_score", queue_health.round(2))

            scope.set_context("queue_performance", queue_stats.merge(
              queue_health_score: queue_health,
              threshold: 0.7
            ))

            Sentry.capture_message("Poor job queue performance detected", level: "warning")
          end
        end

        queue_stats
      rescue => e
        Sentry.capture_exception(e)
        nil
      end
    end

    # Track WebSocket connection performance
    def track_websocket_performance(service, connection_time_ms, message_count = 0)
      return unless enabled?

      performance_tier = categorize_websocket_performance(connection_time_ms)

      SentryHelper.add_breadcrumb(
        message: "WebSocket performance metrics",
        category: "websocket.performance",
        level: (performance_tier == "slow") ? "warning" : "info",
        data: {
          service: service,
          connection_time_ms: connection_time_ms.round(2),
          message_count: message_count,
          performance_tier: performance_tier
        }
      )
    end

    private

    def enabled?
      defined?(Sentry) && ENV["SENTRY_DSN"].present?
    end

    def categorize_api_performance(duration_ms)
      case duration_ms
      when 0..500
        "fast"
      when 500..2000
        "medium"
      when 2000..5000
        "slow"
      else
        "very_slow"
      end
    end

    def categorize_trading_performance(duration_ms)
      case duration_ms
      when 0..1000
        "fast"
      when 1000..3000
        "medium"
      when 3000..10000
        "slow"
      else
        "very_slow"
      end
    end

    def categorize_memory_usage(memory_mb)
      case memory_mb
      when 0..200
        "low"
      when 200..500
        "medium"
      when 500..1000
        "high"
      else
        "very_high"
      end
    end

    def categorize_websocket_performance(connection_time_ms)
      case connection_time_ms
      when 0..1000
        "fast"
      when 1000..5000
        "medium"
      when 5000..15000
        "slow"
      else
        "very_slow"
      end
    end

    def slow_api_threshold
      (ENV["SENTRY_SLOW_API_THRESHOLD"] || 5000).to_f
    end

    def slow_trading_threshold
      (ENV["SENTRY_SLOW_TRADING_THRESHOLD"] || 10000).to_f
    end

    def high_memory_threshold
      (ENV["SENTRY_HIGH_MEMORY_THRESHOLD"] || 1000).to_f
    end

    def get_memory_usage_mb
      return nil unless File.readable?("/proc/meminfo")

      meminfo = File.read("/proc/meminfo")
      if meminfo =~ /MemTotal:\s*(\d+)\s*kB/
        total_kb = $1.to_i
        return total_kb / 1024.0 # Convert to MB
      end

      nil
    rescue
      nil
    end

    def calculate_queue_health(stats)
      # Simple queue health score based on ratios
      total_jobs = stats[:total_queued] + stats[:total_running] + stats[:total_failed]
      return 1.0 if total_jobs == 0

      # Penalize failed jobs more heavily
      failed_ratio = stats[:total_failed].to_f / total_jobs
      queued_ratio = stats[:total_queued].to_f / total_jobs

      # Health score: 1.0 is perfect, 0.0 is terrible
      health_score = 1.0 - (failed_ratio * 0.8) - (queued_ratio * 0.2)
      [health_score, 0.0].max
    end
  end
end
