# frozen_string_literal: true

class HealthCheckJob < ApplicationJob
  queue_as :default

  private

  def logger
    @logger ||= Rails.logger
  end

  public

  def perform(send_slack_notification: false)
    @logger = Rails.logger
    logger.info("Starting health check job")

    health_data = gather_health_data

    # Log health status
    logger.info("Health check results: #{health_data}")

    # Send Slack notification if requested or if there are issues
    if send_slack_notification || health_data[:overall_health] != "healthy"
      SlackNotificationService.health_check(health_data)
    end

    # Store health data for status endpoint
    Rails.cache.write("last_health_check", {
      timestamp: Time.current,
      data: health_data
    }, expires_in: 1.hour)

    logger.info("Completed health check job")

    health_data
  rescue => e
    logger.error("Health check job failed: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    # Send error notification
    SlackNotificationService.alert(
      "error",
      "Health Check Failed",
      "Health check job encountered an error: #{e.message}"
    )

    raise
  end

  private

  def gather_health_data
    health_checks = {}

    # Database connectivity
    health_checks[:database] = check_database_health

    # Coinbase API connectivity
    health_checks[:coinbase_api] = check_coinbase_api_health

    # Background jobs health
    health_checks[:background_jobs] = check_background_jobs_health

    # WebSocket connections
    health_checks[:websocket_connections] = count_websocket_connections

    # Memory usage
    health_checks[:memory_usage] = get_memory_usage

    # Trading status
    health_checks[:trading_active] = check_trading_status

    # Recent signal generation
    health_checks[:recent_signals] = check_recent_signals

    # Position count
    health_checks[:open_positions] = count_open_positions

    # Calculate overall health
    health_checks[:overall_health] = calculate_overall_health(health_checks)

    health_checks
  end

  def check_database_health
    ActiveRecord::Base.connection.active?
  rescue
    false
  end

  def check_coinbase_api_health
    client = Coinbase::Client.new
    result = client.test_auth
    result[:advanced_trade][:ok] == true && result[:exchange][:ok] == true
  rescue => e
    logger.warn("Coinbase API health check failed: #{e.message}")
    false
  end

  def check_background_jobs_health
    # Check if jobs have been processed recently
    recent_jobs = GoodJob::Job.where(finished_at: 1.hour.ago..Time.current).exists?

    # Check if critical jobs are scheduled
    critical_job_classes = %w[
      GenerateSignalsJob
      DayTradingPositionManagementJob
      FetchCandlesJob
    ]

    scheduled_jobs = GoodJob::CronEntry.all.select do |entry|
      critical_job_classes.include?(entry.job_class)
    end

    recent_jobs && scheduled_jobs.any?
  rescue => e
    logger.warn("Background jobs health check failed: #{e.message}")
    false
  end

  def count_websocket_connections
    # This would count active WebSocket connections
    # For now, return a placeholder
    0
  end

  def get_memory_usage
    if File.readable?("/proc/meminfo")
      meminfo = File.read("/proc/meminfo")

      total_match = meminfo.match(/MemTotal:\s+(\d+)\s+kB/)
      available_match = meminfo.match(/MemAvailable:\s+(\d+)\s+kB/)

      if total_match && available_match
        total_kb = total_match[1].to_i
        available_kb = available_match[1].to_i
        used_kb = total_kb - available_kb
        used_percent = (used_kb.to_f / total_kb * 100).round(1)

        "#{used_percent}% used (#{used_kb / 1024} MB / #{total_kb / 1024} MB)"
      else
        "Unable to parse /proc/meminfo"
      end
    else
      "Memory info not available"
    end
  rescue => e
    logger.warn("Memory usage check failed: #{e.message}")
    "Error reading memory info"
  end

  def check_trading_status
    # Check if trading is active (not paused)
    Rails.cache.fetch("trading_active", expires_in: 1.hour) { true }
  end

  def check_recent_signals
    # Check if signals have been generated recently
    recent_signal_job = GoodJob::Job.where(
      job_class: "GenerateSignalsJob",
      finished_at: 2.hours.ago..Time.current
    ).order(finished_at: :desc).first

    recent_signal_job&.finished_at || false
  end

  def count_open_positions
    Position.open.day_trading.count
  rescue
    0
  end

  def calculate_overall_health(checks)
    critical_checks = %i[database background_jobs]
    important_checks = [:coinbase_api]

    # All critical checks must pass
    critical_healthy = critical_checks.all? { |check| checks[check] == true }

    # At least some important checks should pass
    important_healthy = important_checks.any? { |check| checks[check] == true }

    if critical_healthy && important_healthy
      "healthy"
    elsif critical_healthy
      "warning"
    else
      "unhealthy"
    end
  end
end
