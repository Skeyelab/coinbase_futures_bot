# frozen_string_literal: true

# Helper service for Sentry operations with correct API usage
class SentryHelper
  class << self
    # Add breadcrumb with correct API - accepts both hash and keyword arguments
    def add_breadcrumb(message_or_hash = nil, category: "general", level: "info", data: {}, **kwargs)
      return unless enabled?

      # Handle both hash-style and keyword arguments for backward compatibility
      breadcrumb_data = if message_or_hash.is_a?(Hash)
        message_or_hash
      else
        {
          message: message_or_hash || kwargs[:message],
          category: kwargs[:category] || category,
          level: kwargs[:level] || level,
          data: kwargs[:data] || data
        }
      end

      # Use the correct Sentry API
      breadcrumb = Sentry::Breadcrumb.new
      breadcrumb.message = breadcrumb_data[:message]
      breadcrumb.category = breadcrumb_data[:category]
      breadcrumb.level = breadcrumb_data[:level]
      breadcrumb.data = breadcrumb_data[:data] || {}
      breadcrumb.timestamp = Time.current.to_f

      Sentry.add_breadcrumb(breadcrumb)
    end

    # Capture exception with enhanced context
    def capture_exception(exception, **context)
      return unless enabled?

      Sentry.with_scope do |scope|
        context.each do |key, value|
          case key
          when :tags
            value.each { |tag_key, tag_value| scope.set_tag(tag_key, tag_value) }
          when :context
            value.each { |context_key, context_value| scope.set_context(context_key, context_value) }
          when :user
            scope.set_user(value)
          when :level
            scope.set_level(value)
          end
        end

        Sentry.capture_exception(exception)
      end
    end

    # Capture message with enhanced context
    def capture_message(message, level: "info", **context)
      return unless enabled?

      Sentry.with_scope do |scope|
        context.each do |key, value|
          case key
          when :tags
            value.each { |tag_key, tag_value| scope.set_tag(tag_key, tag_value) }
          when :context
            value.each { |context_key, context_value| scope.set_context(context_key, context_value) }
          when :user
            scope.set_user(value)
          end
        end

        Sentry.capture_message(message, level: level)
      end
    end

    # Track performance with transaction
    def track_performance(name, op = "custom", **context, &block)
      return yield unless enabled?

      Sentry.start_transaction(name: name, op: op) do |transaction|
        context.each do |key, value|
          transaction.set_data(key, value)
        end

        yield
      end
    end

    # Track memory usage spikes.
    # Folded in from SentryPerformanceService, which was removed: this and
    # #track_job_queue_performance were its only two called methods (both from
    # `rake sentry:test_performance`).
    def track_memory_usage
      return unless enabled?

      memory_mb = memory_usage_mb
      return unless memory_mb

      memory_tier = categorize_memory_usage(memory_mb)

      add_breadcrumb(
        message: "Memory usage check",
        category: "performance.memory",
        level: (memory_tier == "high") ? "warning" : "info",
        data: {
          memory_mb: memory_mb.round(2),
          memory_tier: memory_tier
        }
      )

      return unless memory_tier == "high"

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

    # Track job queue performance
    def track_job_queue_performance
      return unless enabled?

      queue_stats = {
        total_queued: GoodJob::Job.where(finished_at: nil).count,
        total_running: GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count,
        total_failed: GoodJob::Job.where.not(error: nil).count,
        critical_queued: GoodJob::Job.where(finished_at: nil, queue_name: "critical").count,
        default_queued: GoodJob::Job.where(finished_at: nil, queue_name: "default").count
      }

      queue_health = calculate_queue_health(queue_stats)

      add_breadcrumb(
        message: "Job queue performance check",
        category: "performance.queue",
        level: (queue_health < 0.7) ? "warning" : "info",
        data: queue_stats.merge(queue_health_score: queue_health.round(2))
      )

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

    private

    def enabled?
      defined?(Sentry) && ENV["SENTRY_DSN"].present?
    end

    def categorize_memory_usage(memory_mb)
      case memory_mb
      when 0..200 then "low"
      when 200..500 then "medium"
      when 500..1000 then "high"
      else "very_high"
      end
    end

    def high_memory_threshold
      (ENV["SENTRY_HIGH_MEMORY_THRESHOLD"] || 1000).to_f
    end

    def memory_usage_mb
      return nil unless File.readable?("/proc/meminfo")

      meminfo = File.read("/proc/meminfo")
      return $1.to_i / 1024.0 if meminfo =~ /MemTotal:\s*(\d+)\s*kB/

      nil
    rescue
      nil
    end

    def calculate_queue_health(stats)
      total_jobs = stats[:total_queued] + stats[:total_running] + stats[:total_failed]
      return 1.0 if total_jobs == 0

      # Penalize failed jobs more heavily than merely queued ones.
      failed_ratio = stats[:total_failed].to_f / total_jobs
      queued_ratio = stats[:total_queued].to_f / total_jobs

      health_score = 1.0 - (failed_ratio * 0.8) - (queued_ratio * 0.2)
      [health_score, 0.0].max
    end
  end
end
