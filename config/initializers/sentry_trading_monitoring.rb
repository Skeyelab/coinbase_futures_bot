# frozen_string_literal: true

# Additional Sentry configuration specific to trading bot monitoring
if defined?(Sentry) && ENV["SENTRY_DSN"].present?

  # Add custom transaction names for better organization
  Sentry.configure_scope do |scope|
    scope.set_tag("application", "coinbase_futures_bot")
    scope.set_tag("version", ENV["APP_VERSION"] || "unknown")
    scope.set_context("environment", {
      rails_env: Rails.env,
      trading_mode: (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live",
      sentiment_enabled: ENV["SENTIMENT_ENABLE"] == "true",
      database_url_present: ENV["DATABASE_URL"].present?,
      coinbase_credentials_present: File.exist?(Rails.root.join("cdp_api_key.json"))
    })
  end

  # Subscribe to ActiveJob events for enhanced job monitoring
  ActiveSupport::Notifications.subscribe("enqueue.active_job") do |name, started, finished, unique_id, data|
    SentryHelper.add_breadcrumb(
      message: "Job enqueued",
      category: "job",
      level: "debug",
      data: {
        job_class: data[:job].class.name,
        queue_name: data[:job].queue_name,
        job_id: data[:job].job_id,
        scheduled_at: data[:job].scheduled_at&.iso8601
      }
    )
  end

  ActiveSupport::Notifications.subscribe("perform_start.active_job") do |name, started, finished, unique_id, data|
    SentryHelper.add_breadcrumb(
      message: "Job execution started",
      category: "job",
      level: "info",
      data: {
        job_class: data[:job].class.name,
        queue_name: data[:job].queue_name,
        job_id: data[:job].job_id,
        executions: data[:job].executions
      }
    )
  end

  ActiveSupport::Notifications.subscribe("perform.active_job") do |name, started, finished, unique_id, data|
    duration = (finished - started) * 1000 # Convert to milliseconds

    SentryHelper.add_breadcrumb(
      message: "Job execution completed",
      category: "job",
      level: "info",
      data: {
        job_class: data[:job].class.name,
        queue_name: data[:job].queue_name,
        job_id: data[:job].job_id,
        duration_ms: duration.round(2),
        executions: data[:job].executions
      }
    )

    # Track long-running jobs
    if duration > 30000 # 30 seconds
      Sentry.with_scope do |scope|
        scope.set_tag("performance", "long_running_job")
        scope.set_tag("job_class", data[:job].class.name)
        scope.set_context("long_running_job", {
          job_class: data[:job].class.name,
          duration_ms: duration.round(2),
          queue_name: data[:job].queue_name,
          executions: data[:job].executions
        })

        Sentry.capture_message("Long-running job detected", level: "warning")
      end
    end
  end

  # Subscribe to ActionController events for API monitoring
  ActiveSupport::Notifications.subscribe("process_action.action_controller") do |name, started, finished, unique_id, data|
    duration = (finished - started) * 1000 # Convert to milliseconds

    # Track slow API requests
    if duration > 5000 # 5 seconds
      Sentry.with_scope do |scope|
        scope.set_tag("performance", "slow_api_request")
        scope.set_tag("controller", data[:controller])
        scope.set_tag("action", data[:action])
        scope.set_context("slow_request", {
          controller: data[:controller],
          action: data[:action],
          duration_ms: duration.round(2),
          status: data[:status],
          method: data[:method],
          path: data[:path]
        })

        Sentry.capture_message("Slow API request detected", level: "warning")
      end
    end
  end

  # Monitor ActionCable events
  ActiveSupport::Notifications.subscribe("subscribe.action_cable") do |name, started, finished, unique_id, data|
    SentryHelper.add_breadcrumb(
      message: "ActionCable subscription",
      category: "websocket",
      level: "info",
      data: {
        channel: data[:channel_class],
        connection_id: data[:connection_identifier]
      }
    )
  end

  ActiveSupport::Notifications.subscribe("unsubscribe.action_cable") do |name, started, finished, unique_id, data|
    SentryHelper.add_breadcrumb(
      message: "ActionCable unsubscription",
      category: "websocket",
      level: "info",
      data: {
        channel: data[:channel_class],
        connection_id: data[:connection_identifier]
      }
    )
  end

  # Custom trading event tracking
  ActiveSupport::Notifications.subscribe("signal.generated") do |name, started, finished, unique_id, data|
    SentryMonitoringService.track_signal_generated(data[:signal])
  end

  ActiveSupport::Notifications.subscribe("position.opened") do |name, started, finished, unique_id, data|
    SentryMonitoringService.track_position_opened(data[:position])
  end

  ActiveSupport::Notifications.subscribe("position.closed") do |name, started, finished, unique_id, data|
    SentryMonitoringService.track_position_closed(data[:position], data[:reason])
  end

  # Monitor critical system events
  ActiveSupport::Notifications.subscribe("health_check.completed") do |name, started, finished, unique_id, data|
    SentryMonitoringService.track_health_check(data[:health_data], data[:overall_healthy])
  end

  Rails.logger.info("[Sentry] Trading-specific monitoring initialized")
end
