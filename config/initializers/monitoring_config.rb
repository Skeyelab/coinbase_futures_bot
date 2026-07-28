# frozen_string_literal: true

# Configuration for monitoring and alerting thresholds
Rails.application.configure do
  config.monitoring_config = {
    # Position exposure limits, in PERCENT of equity — these are compared against
    # HealthCheckJob#exposure_percent, which already multiplies by 100.
    #
    # They were 0.5 and 0.3, which read as fractions (50%/30%) but were compared
    # against a percentage, so the real ceiling was HALF OF ONE PERCENT. On a
    # $10,072 account that allowed $50.36 of notional — less than a single
    # contract — so no position the bot can open could satisfy it, and the health
    # card reported "Warning" every hour forever (issue #536).
    #
    # The tell that it was a units error rather than caution: Trading::NotionalCap,
    # which actually blocks orders, permits 2.0x equity = 200% exposure. An
    # advisory warning does not get set 400x below the limit that is enforced.
    #
    # 50/30 warns at a quarter of that hard cap, which is deliberate — a warning
    # is only useful with enough headroom left to act on it.
    max_day_trading_exposure: ENV.fetch("MAX_DAY_EXPOSURE", 50.0).to_f,
    max_swing_trading_exposure: ENV.fetch("MAX_SWING_EXPOSURE", 30.0).to_f,

    # Portfolio exposure monitoring
    portfolio_exposure_warning_threshold: ENV.fetch("EXPOSURE_WARNING_THRESHOLD", 0.8).to_f,

    # Leverage limits
    leverage_warning_threshold: ENV.fetch("LEVERAGE_WARNING_THRESHOLD", 5.0).to_f,
    max_day_trading_leverage: ENV.fetch("MAX_DAY_LEVERAGE", 10.0).to_f,
    max_swing_trading_leverage: ENV.fetch("MAX_SWING_LEVERAGE", 5.0).to_f,

    # Position duration monitoring
    day_trading_max_duration_hours: ENV.fetch("DAY_TRADING_MAX_HOURS", 8).to_f,
    swing_trading_max_duration_days: ENV.fetch("SWING_TRADING_MAX_DAYS", 14).to_f,

    # Alert settings
    enable_position_type_alerts: ENV.fetch("ENABLE_POSITION_TYPE_ALERTS", true),
    margin_window_monitoring_enabled: ENV.fetch("MARGIN_WINDOW_MONITORING", true),

    # Risk thresholds
    liquidation_buffer_warning: ENV.fetch("LIQUIDATION_BUFFER_WARNING", 0.15).to_f, # 15%
    margin_utilization_warning: ENV.fetch("MARGIN_UTILIZATION_WARNING", 0.8).to_f, # 80%

    # PnL monitoring
    daily_loss_threshold: ENV.fetch("DAILY_LOSS_THRESHOLD", -1000.0).to_f,
    position_loss_threshold: ENV.fetch("POSITION_LOSS_THRESHOLD", -500.0).to_f,

    # Notification channels
    slack_notifications: {
      day_trading_channel: ENV["SLACK_DAY_TRADING_CHANNEL"] || "#day-trading",
      swing_trading_channel: ENV["SLACK_SWING_TRADING_CHANNEL"] || "#swing-trading",
      risk_alerts_channel: ENV["SLACK_RISK_ALERTS_CHANNEL"] || "#risk-alerts",
      margin_alerts_channel: ENV["SLACK_MARGIN_ALERTS_CHANNEL"] || "#margin-alerts"
    }
  }
end
