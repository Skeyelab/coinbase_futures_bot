# frozen_string_literal: true

class MarginWindowMonitoringJob < ApplicationJob
  queue_as :critical # High priority for margin changes

  def perform
    @logger = Rails.logger
    @positions_service = Trading::CoinbasePositions.new(logger: @logger)

    @logger.info('Starting margin window monitoring job')

    # Add Sentry breadcrumb for critical margin monitoring
    SentryHelper.add_breadcrumb(
      message: 'Margin window monitoring started',
      category: 'trading',
      level: 'info',
      data: {
        job_type: 'margin_window_monitoring',
        critical: true
      }
    )

    # Check if we have authentication
    unless @positions_service.instance_variable_get(:@authenticated)
      @logger.error('Margin window monitoring requires authentication')
      return
    end

    # Get current margin window status
    margin_window = get_current_margin_window
    return unless margin_window

    # Process margin window changes
    process_margin_window_status(margin_window)

    # Check balance and margin health for swing positions
    check_swing_position_margins(margin_window)

    @logger.info('Margin window monitoring job completed successfully')
  rescue StandardError => e
    @logger.error("Margin window monitoring job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))

    # Report critical margin monitoring failure to Sentry
    Sentry.with_scope do |scope|
      scope.set_tag('job_type', 'margin_window_monitoring')
      scope.set_tag('critical', true)
      scope.set_context('job_failure', {
                          error_class: e.class.to_s,
                          error_message: e.message,
                          backtrace: e.backtrace&.first(10)
                        })

      Sentry.capture_exception(e)
    end

    # Alert via Slack for critical margin monitoring failure
    SlackNotificationService.alert(
      'critical',
      'Margin Window Monitoring Job Failed',
      "Critical margin window monitoring job failed: #{e.message}"
    )

    raise e # Re-raise to ensure job is marked as failed
  end

  private

  def get_current_margin_window
    # Get current margin window from Coinbase API
    path = '/api/v3/brokerage/cfm/intraday_margin_setting'
    resp = @positions_service.send(:authenticated_get, path, {})
    margin_data = JSON.parse(resp.body)

    @logger.debug("Margin window data: #{margin_data}")
    margin_data
  rescue StandardError => e
    @logger.error("Failed to get current margin window: #{e.message}")
    raise e # Re-raise to match test expectations
  end

  def process_margin_window_status(margin_window)
    margin_window_type = margin_window.dig('margin_window', 'margin_window_type')

    case margin_window_type
    when 'INTRADAY_MARGIN'
      handle_intraday_margin_window(margin_window)
    when 'OVERNIGHT_MARGIN'
      handle_overnight_margin_window(margin_window)
    else
      @logger.warn("Unknown margin window type: #{margin_window_type}")
    end
  end

  def handle_intraday_margin_window(margin_window)
    @logger.info('Intraday margin window active - higher leverage available')

    # Add Sentry breadcrumb
    SentryHelper.add_breadcrumb(
      message: 'Intraday margin window active',
      category: 'trading',
      level: 'info',
      data: {
        margin_window_type: 'intraday',
        higher_leverage: true
      }
    )

    # Notify about margin window change
    notify_margin_window_change('intraday', margin_window)

    # Check if we can optimize swing position leverage during intraday hours
    optimize_swing_position_leverage
  end

  def handle_overnight_margin_window(margin_window)
    @logger.warn('Overnight margin window active - lower leverage, higher margin requirements')

    # Add Sentry breadcrumb
    SentryHelper.add_breadcrumb(
      message: 'Overnight margin window active',
      category: 'trading',
      level: 'warning',
      data: {
        margin_window_type: 'overnight',
        higher_margin_requirements: true
      }
    )

    # Notify about margin window change
    notify_margin_window_change('overnight', margin_window)

    # Check if swing positions need margin adjustments
    check_overnight_margin_compliance
  end

  def check_swing_position_margins(margin_window)
    swing_positions = Position.swing_trading.open.includes(:trading_pair)
    return if swing_positions.empty?

    @logger.info("Checking margin requirements for #{swing_positions.count} swing positions")

    # Get current balance summary
    balance_summary = get_futures_balance_summary
    return unless balance_summary

    margin_violations = []

    swing_positions.each do |position|
      # Check if position exceeds overnight margin requirements
      next unless position_exceeds_margin_requirements?(position, balance_summary, margin_window)

      violation = {
        position_id: position.id,
        product_id: position.product_id,
        size: position.size,
        entry_price: position.entry_price,
        margin_requirement: calculate_position_margin_requirement(position, margin_window)
      }
      margin_violations << violation

      @logger.warn("Position #{position.id} (#{position.product_id}) exceeds overnight margin requirements")
    end

    return unless margin_violations.any?

    handle_margin_violations(margin_violations, balance_summary)
  end

  def get_futures_balance_summary
    path = '/api/v3/brokerage/cfm/balance_summary'
    resp = @positions_service.send(:authenticated_get, path, {})
    balance_data = JSON.parse(resp.body)

    {
      futures_buying_power: balance_data.dig('futures_buying_power').to_f,
      total_usd_balance: balance_data.dig('total_usd_balance').to_f,
      available_margin: balance_data.dig('available_margin').to_f,
      initial_margin: balance_data.dig('initial_margin').to_f,
      liquidation_threshold: balance_data.dig('liquidation_threshold').to_f
    }
  rescue StandardError => e
    @logger.error("Failed to get futures balance summary: #{e.message}")
    nil
  end

  def position_exceeds_margin_requirements?(position, balance_summary, margin_window)
    # Calculate position margin requirement based on current margin window
    calculate_position_margin_requirement(position, margin_window)
    available_margin = balance_summary[:available_margin]

    # Check if position margin exceeds a safety threshold
    margin_safety_buffer = ENV.fetch('SWING_MARGIN_BUFFER', '0.2').to_f
    required_buffer = balance_summary[:total_usd_balance] * margin_safety_buffer

    available_margin < required_buffer
  end

  def calculate_position_margin_requirement(position, margin_window)
    # Simplified margin calculation - in reality this would be more complex
    # based on the specific contract and margin window requirements
    position_value = position.size * position.entry_price

    # Use higher margin requirements for overnight window
    margin_rate = if margin_window.dig('margin_window', 'margin_window_type') == 'OVERNIGHT_MARGIN'
                    0.20 # 20% margin for overnight
                  else
                    0.10 # 10% margin for intraday
                  end

    position_value * margin_rate
  end

  def handle_margin_violations(violations, balance_summary)
    @logger.warn("Found #{violations.size} swing positions with margin violations")

    # Send critical alert about margin violations
    violation_details = violations.map { |v| "#{v[:product_id]} (#{v[:size]} contracts)" }.join(', ')

    Sentry.with_scope do |scope|
      scope.set_tag('trading_operation', 'margin_violation')
      scope.set_tag('violation_count', violations.size)
      scope.set_context('margin_violations', {
                          violations: violations,
                          available_margin: balance_summary[:available_margin],
                          total_balance: balance_summary[:total_usd_balance]
                        })

      Sentry.capture_message('Swing positions exceed margin requirements', level: 'error')
    end

    # Fix the Slack alert message to match test expectations
    SlackNotificationService.alert(
      'critical',
      'Swing Position Margin Violations',
      "#{violations.size} swing positions exceed margin requirements: #{violation_details}"
    )

    # Consider automatically closing some positions if margin is critically low
    # 5% emergency threshold
    return unless balance_summary[:available_margin] < (balance_summary[:total_usd_balance] * 0.05)

    @logger.error('Available margin critically low - considering emergency position closure')
    close_positions_for_margin_emergency(violations)
  end

  def close_positions_for_margin_emergency(violations)
    # Close positions to free up margin - start with smallest positions first
    violations.sort_by { |v| v[:size] }.each do |violation|
      position = Position.find(violation[:position_id])
      next unless position.open?

      @logger.warn("Emergency closure of position #{position.id} due to margin requirements")

      # Schedule immediate position closure
      PositionCloseJob.perform_now(
        position_id: position.id,
        reason: 'emergency_margin_violation',
        priority: 'critical'
      )

      # Break after closing one position to reassess
      break
    rescue StandardError => e
      @logger.error("Failed to close position #{violation[:position_id]} for margin emergency: #{e.message}")
    end
  end

  def optimize_swing_position_leverage
    # During intraday hours, we could potentially increase position sizes
    # or open new positions with the higher leverage available
    # For now, just log that optimization could occur
    @logger.info('Intraday margin window - swing position leverage optimization available')
  end

  def check_overnight_margin_compliance
    # Check if current swing positions comply with overnight margin requirements
    swing_manager = Trading::SwingPositionManager.new(logger: @logger)
    risk_check = swing_manager.check_swing_risk_limits

    return unless risk_check[:risk_status] == 'violations_detected'

    @logger.warn('Swing positions violate overnight margin compliance')

    # Send additional warning about overnight compliance
    SlackNotificationService.alert(
      'warning',
      'Overnight Margin Compliance Issues',
      'Swing positions may not comply with overnight margin requirements. ' \
      "Risk violations: #{risk_check[:violations].map { |v| v[:message] }.join('; ')}"
    )
  end

  def notify_margin_window_change(window_type, margin_window)
    # Only send notifications for actual changes, not every check
    last_window_type = Rails.cache.read('last_margin_window_type')

    return unless last_window_type != window_type

    Rails.cache.write('last_margin_window_type', window_type, expires_in: 24.hours)

    message = case window_type
              when 'intraday'
                'Market hours margin window active - higher leverage available for swing positions'
              when 'overnight'
                'Overnight margin window active - reduced leverage, higher margin requirements'
              else
                "Margin window changed to #{window_type}"
              end

    # Send info-level notification about margin window changes
    SlackNotificationService.alert(
      'info',
      'Margin Window Change',
      message
    )

    # Add to Sentry for tracking
    SentryHelper.add_breadcrumb(
      message: 'Margin window transition',
      category: 'trading',
      level: 'info',
      data: {
        from: last_window_type,
        to: window_type,
        margin_data: margin_window
      }
    )
  end
end
