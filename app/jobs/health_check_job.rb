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

    # Enhanced Sentry tracking for health check failures
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "health_check")
      scope.set_tag("error_type", "health_check_failure")
      scope.set_tag("critical", "true")

      # Try to gather partial health data for context
      partial_health = begin
        gather_health_data
      rescue
        {error: "Could not gather health data"}
      end

      scope.set_context("health_status", partial_health)

      Sentry.capture_exception(e)
    end

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

    # Position count (both day trading and swing)
    health_checks[:open_positions] = count_open_positions

    # Day trading position monitoring
    health_checks[:day_trading_positions] = check_day_trading_positions_health

    # Swing position monitoring
    health_checks[:swing_positions] = check_swing_positions_health

    # Margin and balance monitoring
    health_checks[:margin_health] = check_margin_health

    # Margin window status
    health_checks[:margin_window] = check_margin_window_status

    # Portfolio exposure monitoring
    health_checks[:portfolio_exposure] = check_portfolio_exposure

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
    api_healthy = result[:advanced_trade][:ok] == true && result[:exchange][:ok] == true

    # Track API health status
    SentryHelper.add_breadcrumb(
      message: "Coinbase API health check completed",
      category: "health_check",
      level: api_healthy ? "info" : "warning",
      data: {
        advanced_trade_ok: result[:advanced_trade][:ok],
        exchange_ok: result[:exchange][:ok],
        overall_healthy: api_healthy
      }
    )

    api_healthy
  rescue => e
    logger.warn("Coinbase API health check failed: #{e.message}")

    # Track API health failures
    Sentry.with_scope do |scope|
      scope.set_tag("health_check_type", "coinbase_api")
      scope.set_tag("error_type", "api_health_failure")

      Sentry.capture_exception(e)
    end

    false
  end

  def check_background_jobs_health
    # Check if jobs have been processed recently
    recent_jobs = GoodJob::Job.where(finished_at: 1.hour.ago..Time.current).exists?

    # Check if critical jobs are scheduled
    critical_job_classes = %w[
      GenerateSignalsJob
      DayTradingPositionManagementJob
      SwingPositionManagementJob
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
    {
      day_trading: Position.open.day_trading.count,
      swing_trading: Position.open.swing_trading.count,
      total: Position.open.count
    }
  rescue
    {day_trading: 0, swing_trading: 0, total: 0}
  end

  def check_swing_positions_health
    swing_manager = Trading::SwingPositionManager.new(logger: logger)

    # Get swing position summary
    summary = swing_manager.get_swing_position_summary

    # Check for risk violations
    risk_check = swing_manager.check_swing_risk_limits

    {
      total_positions: summary[:total_positions],
      total_exposure: summary[:total_exposure].round(2),
      unrealized_pnl: summary[:unrealized_pnl].round(2),
      risk_status: risk_check[:risk_status],
      positions_approaching_expiry: swing_manager.positions_approaching_expiry.count,
      positions_exceeding_max_hold: swing_manager.positions_exceeding_max_hold.count,
      healthy: risk_check[:risk_status] == "acceptable"
    }
  rescue => e
    logger.warn("Swing position health check failed: #{e.message}")
    {error: e.message, healthy: false}
  end

  def check_day_trading_positions_health
    day_positions = Position.open.day_trading
    
    {
      total_positions: day_positions.count,
      positions_approaching_closure: day_positions.where("entry_time < ?", 23.hours.ago).count,
      positions_needing_closure: day_positions.where("entry_time < ?", 24.hours.ago).count,
      total_exposure: calculate_day_trading_exposure,
      average_duration_hours: calculate_average_duration(day_positions),
      healthy: day_positions.where("entry_time < ?", 24.hours.ago).count == 0
    }
  rescue => e
    logger.warn("Day trading position health check failed: #{e.message}")
    {error: e.message, healthy: false}
  end

  def check_margin_health
    client = Coinbase::Client.new
    balance_summary = client.futures_balance_summary
    balance = balance_summary['balance_summary']
    
    # Separate margin monitoring for position types
    {
      day_trading: {
        exposure: calculate_day_trading_exposure,
        margin_used: calculate_day_trading_margin(balance),
        leverage: calculate_day_trading_leverage(balance)
      },
      swing_trading: {
        exposure: calculate_swing_trading_exposure,
        margin_used: calculate_swing_trading_margin(balance),
        leverage: calculate_swing_trading_leverage(balance),
        overnight_margin: balance['overnight_margin_window_measure']
      },
      overall: {
        total_margin: balance['initial_margin']['value'],
        available_margin: balance['available_margin']['value'],
        liquidation_buffer: balance['liquidation_buffer_percentage'],
        unrealized_pnl: balance['unrealized_pnl']['value']
      }
    }
  rescue => e
    logger.warn("Margin health check failed: #{e.message}")
    {error: e.message, healthy: false}
  end

  def check_margin_window_status
    client = Coinbase::Client.new
    margin_window = client.margin_window
    
    {
      current_window: margin_window['margin_window']['margin_window_type'],
      window_end_time: margin_window['margin_window']['end_time'],
      intraday_killswitch: margin_window['is_intraday_margin_killswitch_enabled'],
      enrollment_killswitch: margin_window['is_intraday_margin_enrollment_killswitch_enabled'],
      next_transition: calculate_next_margin_transition(margin_window)
    }
  rescue => e
    logger.warn("Margin window status check failed: #{e.message}")
    {error: e.message, current_window: "unknown"}
  end

  def check_portfolio_exposure
    day_exposure = calculate_day_trading_exposure
    swing_exposure = calculate_swing_trading_exposure
    total_exposure = day_exposure + swing_exposure
    
    max_day_exposure = Rails.application.config.monitoring_config[:max_day_trading_exposure]
    max_swing_exposure = Rails.application.config.monitoring_config[:max_swing_trading_exposure]
    
    warnings = []
    
    if day_exposure > max_day_exposure
      warnings << "Day trading exposure: #{day_exposure.round(2)}% (max: #{max_day_exposure}%)"
    end
    
    if swing_exposure > max_swing_exposure
      warnings << "Swing trading exposure: #{swing_exposure.round(2)}% (max: #{max_swing_exposure}%)"
    end
    
    {
      day_trading_exposure: day_exposure.round(2),
      swing_trading_exposure: swing_exposure.round(2),
      total_exposure: total_exposure.round(2),
      warnings: warnings,
      healthy: warnings.empty?
    }
  rescue => e
    logger.warn("Portfolio exposure check failed: #{e.message}")
    {error: e.message, healthy: false}
  end

  private

  def calculate_day_trading_exposure
    day_positions = Position.open.day_trading
    return 0.0 if day_positions.empty?
    
    total_notional = day_positions.sum { |pos| pos.size * pos.entry_price }
    # Assume total portfolio value for now - this should be replaced with actual account balance
    total_portfolio_value = 100_000.0 # This should come from Coinbase balance
    
    (total_notional / total_portfolio_value * 100).to_f
  end

  def calculate_swing_trading_exposure
    swing_positions = Position.open.swing_trading
    return 0.0 if swing_positions.empty?
    
    total_notional = swing_positions.sum { |pos| pos.size * pos.entry_price }
    # Assume total portfolio value for now - this should be replaced with actual account balance
    total_portfolio_value = 100_000.0 # This should come from Coinbase balance
    
    (total_notional / total_portfolio_value * 100).to_f
  end

  def calculate_day_trading_margin(balance)
    # Calculate margin used specifically for day trading positions
    day_positions = Position.open.day_trading
    return 0.0 if day_positions.empty?
    
    # This is a simplified calculation - in reality this would need to be calculated
    # based on the specific margin requirements for each position
    total_notional = day_positions.sum { |pos| pos.size * pos.entry_price }
    total_notional * 0.1 # Assume 10% margin requirement for day trading
  end

  def calculate_swing_trading_margin(balance)
    # Calculate margin used specifically for swing trading positions
    swing_positions = Position.open.swing_trading
    return 0.0 if swing_positions.empty?
    
    # Use overnight margin requirements for swing positions
    total_notional = swing_positions.sum { |pos| pos.size * pos.entry_price }
    total_notional * 0.2 # Assume 20% margin requirement for swing trading (overnight)
  end

  def calculate_day_trading_leverage(balance)
    day_positions = Position.open.day_trading
    total_notional = day_positions.sum { |pos| pos.size * pos.entry_price }
    margin_used = calculate_day_trading_margin(balance)
    
    return 0.0 if margin_used.zero?
    total_notional / margin_used
  end

  def calculate_swing_trading_leverage(balance)
    swing_positions = Position.open.swing_trading
    total_notional = swing_positions.sum { |pos| pos.size * pos.entry_price }
    margin_used = calculate_swing_trading_margin(balance)
    
    return 0.0 if margin_used.zero?
    total_notional / margin_used
  end

  def calculate_average_duration(positions)
    return 0.0 if positions.empty?
    
    total_duration = positions.sum { |pos| (Time.current - pos.entry_time) / 1.hour }
    total_duration / positions.count
  end

  def calculate_next_margin_transition(margin_window)
    current_window = margin_window['margin_window']['margin_window_type']
    end_time = Time.parse(margin_window['margin_window']['end_time'])
    
    if current_window == 'INTRADAY_MARGIN'
      "Switches to overnight margin at #{end_time.strftime('%H:%M UTC')}"
    else
      "Switches to intraday margin at #{end_time.strftime('%H:%M UTC')}"
    end
  rescue
    "Unable to calculate next transition"
  end

  def calculate_overall_health(checks)
    critical_checks = %i[database background_jobs]
    important_checks = [:coinbase_api]

    # All critical checks must pass
    critical_healthy = critical_checks.all? { |check| checks[check] == true }

    # At least some important checks should pass
    important_healthy = important_checks.any? { |check| checks[check] == true }

    # Check for position-specific issues
    position_issues = []
    position_issues << "day trading positions need closure" if checks.dig(:day_trading_positions, :healthy) == false
    position_issues << "swing position risk limits exceeded" if checks.dig(:swing_positions, :healthy) == false
    position_issues << "portfolio exposure limits exceeded" if checks.dig(:portfolio_exposure, :healthy) == false

    if critical_healthy && important_healthy && position_issues.empty?
      "healthy"
    elsif critical_healthy && important_healthy
      "warning"
    elsif critical_healthy
      "warning"
    else
      "unhealthy"
    end
  end
end
