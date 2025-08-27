# frozen_string_literal: true

# Configuration for Real-Time Signal System
Rails.application.config.real_time_signals = {
  # Signal evaluation settings
  evaluation_interval: ENV.fetch('REALTIME_SIGNAL_EVALUATION_INTERVAL', '30').to_i, # seconds

  # Signal filtering settings
  min_confidence_threshold: ENV.fetch('REALTIME_SIGNAL_MIN_CONFIDENCE', '60').to_f,
  max_signals_per_hour: ENV.fetch('REALTIME_SIGNAL_MAX_PER_HOUR', '10').to_i,
  deduplication_window: ENV.fetch('REALTIME_SIGNAL_DEDUPE_WINDOW', '300').to_i, # seconds

  # Broadcasting settings
  broadcast_enabled: ENV.fetch('SIGNAL_BROADCAST_ENABLED', 'true').to_s.casecmp('true').zero?,
  websocket_channel: 'signals',

  # Candle aggregation settings
  candle_aggregation_enabled: ENV.fetch('CANDLE_AGGREGATION_ENABLED', 'true').to_s.casecmp('true').zero?,
  supported_timeframes: %w[1m 5m 15m 1h],

  # Strategy settings
  strategies: {
    'MultiTimeframeSignal' => {
      ema_1h_short: 21,
      ema_1h_long: 50,
      ema_15m: 21,
      ema_5m: 13,
      ema_1m: 8,
      min_1h_candles: 60,
      min_15m_candles: 80,
      min_5m_candles: 100,
      min_1m_candles: 60,
      tp_target: 0.006,        # 60 bps take profit (more aggressive)
      sl_target: 0.004,        # 40 bps stop loss (wider for swing trades)
      risk_fraction: 0.02,     # 2% of equity per trade (for 10 contract positions)
      contract_size_usd: 100.0, # BTC/ETH futures contract size
      max_position_size: 15,   # Max 15 contracts (allows 10 ETH + some buffer)
      min_position_size: 5     # Min 5 contracts (avoids tiny positions)
    }
  },

  # API settings
  api_key: ENV['SIGNALS_API_KEY'],
  cors_origins: ENV.fetch('SIGNALS_CORS_ORIGINS', '*').split(','),

  # Logging settings
  log_level: ENV.fetch('REALTIME_SIGNAL_LOG_LEVEL', 'info'),
  enable_debug_logging: ENV.fetch('REALTIME_SIGNAL_DEBUG', 'false').to_s.casecmp('true').zero?
}

# Validate configuration on startup
Rails.application.config.after_initialize do
  config = Rails.application.config.real_time_signals

  # Validate evaluation interval
  if config[:evaluation_interval] < 5
    Rails.logger.warn("[RTS] Evaluation interval #{config[:evaluation_interval]}s is very low, may cause performance issues")
  end

  # Validate confidence threshold
  if config[:min_confidence_threshold] < 0 || config[:min_confidence_threshold] > 100
    raise "Invalid confidence threshold: #{config[:min_confidence_threshold]}. Must be between 0 and 100."
  end

  # Log configuration
  Rails.logger.info('[RTS] Real-time signals configuration loaded:')
  Rails.logger.info("[RTS]   Evaluation interval: #{config[:evaluation_interval]}s")
  Rails.logger.info("[RTS]   Min confidence: #{config[:min_confidence_threshold]}%")
  Rails.logger.info("[RTS]   Max signals/hour: #{config[:max_signals_per_hour]}")
  Rails.logger.info("[RTS]   Broadcast enabled: #{config[:broadcast_enabled]}")
  Rails.logger.info("[RTS]   Candle aggregation: #{config[:candle_aggregation_enabled]}")
end
