# frozen_string_literal: true

# Configuration for Real-Time Signal System
Rails.application.config.real_time_signals = {
  # Signal evaluation settings
  evaluation_interval: ENV.fetch("REALTIME_SIGNAL_EVALUATION_INTERVAL", "30").to_i, # seconds

  # Signal filtering settings
  min_confidence_threshold: ENV.fetch("REALTIME_SIGNAL_MIN_CONFIDENCE", "60").to_f,
  max_signals_per_hour: ENV.fetch("REALTIME_SIGNAL_MAX_PER_HOUR", "10").to_i,
  deduplication_window: ENV.fetch("REALTIME_SIGNAL_DEDUPE_WINDOW", "300").to_i, # seconds

  # Broadcasting settings
  broadcast_enabled: ENV.fetch("SIGNAL_BROADCAST_ENABLED", "true").to_s.casecmp("true").zero?,
  websocket_channel: "signals",

  # Candle aggregation settings
  candle_aggregation_enabled: ENV.fetch("CANDLE_AGGREGATION_ENABLED", "true").to_s.casecmp("true").zero?,
  supported_timeframes: %w[1m 5m 15m 1h],

  # Strategy settings
  strategies: {
    "MultiTimeframeSignal" => {
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

  # Minimum-ROI time-decay exit (issue #398, ADR 0003). A {minutes_held =>
  # profit_ratio} schedule that lowers the take-profit bar as a position ages, so
  # stalled winners are booked before round-tripping to break-even. Inert by
  # default (empty schedule) — opt in globally via `schedule` or per symbol via
  # `per_symbol`. Ratios are price returns, same units as tp_target.
  #   Example: {schedule: {0 => 0.006, 20 => 0.004, 40 => 0.002, 60 => 0.0}}
  min_roi: {
    schedule: {},
    per_symbol: {}
  },

  # Trailing profit-giveback exit — the operator's real rule, ported from the n8n
  # workflow that had been closing positions outside this bot. See
  # docs/plans/2026-07-29-trailing-profit-giveback-exit-design.md.
  #
  # Arm once net profit per contract clears `arm_at_per_contract_usd`, then exit on
  # giving back `giveback_fraction` of the peak. Unarmed, `hard_stop_per_contract_usd`
  # is the only exit. All dollar figures are PER CONTRACT and measured NET of the
  # round-trip fee: on dated futures the fee is a flat per-contract charge (~$0.85/side
  # on NOL), so a fixed TOTAL target decays to nothing as size grows.
  #
  # Inert by default (nil thresholds), matching DollarExitPolicy and MinimumRoiExit.
  # Operator values from 2026-07-29: 25.0 / 0.30 / 15.0.
  #
  # NOTE: enabling this SUPPRESSES the strategy's take-profit for day trades, because
  # tp_target (60bps) fires ~5x sooner than the arm threshold and would keep the trail
  # from ever arming. The strategy's stop_loss stays live.
  #
  # One threshold set serves every symbol for now. Per-symbol overrides were deferred
  # until a backtest shows whether that holds — $25/contract is 2.50% of notional on
  # BIT and 3.79% on BIP.
  trailing_giveback: {
    arm_at_per_contract_usd: ENV["TRAIL_ARM_PROFIT_PER_CONTRACT_USD"]&.to_f,
    giveback_fraction: ENV["TRAIL_GIVEBACK_FRACTION"]&.to_f,
    hard_stop_per_contract_usd: ENV["TRAIL_HARD_STOP_PER_CONTRACT_USD"]&.to_f
  },

  # Liquidation buffer (issue #399, ADR 0003). Close a leveraged position before
  # it reaches the exchange's liquidation price. `buffer` is the fraction of the
  # entry→liq distance kept as a safety margin (default 0.05). Set buffer: 0 to
  # disable. Per-symbol overrides via `per_symbol`.
  #
  # `leverage` has NO default on purpose. Leverage comes from the contract's real
  # per-side intraday margin rate (contracts.intraday_margin_rate_*, populated
  # from the products API). It used to default to 10.0, which silently
  # under-protected anything more levered: on PAU (5% intraday = 20x) the
  # assumed-10x exit sat at ~9.0% adverse while real liquidation is ~4.5%, so the
  # buffer could never fire in time. A contract with no stored margin and no
  # explicit override now leaves the buffer UNARMED and logs it, rather than
  # arming on a number nobody checked.
  liquidation_buffer: {
    buffer: ENV.fetch("LIQUIDATION_BUFFER", "0.05").to_f,
    leverage: ENV["LIQUIDATION_ASSUMED_LEVERAGE"]&.to_f,
    maintenance_margin_rate: ENV.fetch("LIQUIDATION_MAINTENANCE_MARGIN_RATE", "0.005").to_f,
    per_symbol: {}
  },

  # Protections layer (issue #397, ADR 0003). Strategy-agnostic entry guards.
  protections: {
    # CooldownPeriod: block re-entry on a symbol for this many seconds after any
    # exit. Per-symbol overrides may be resolved from a calibrated TradingProfile.
    cooldown_seconds: ENV.fetch("PROTECTION_COOLDOWN_SECONDS", "300").to_i,

    # StoplossGuard (issue #400): after `threshold` losing exits within
    # `lookback_seconds`, halt new entries for `lock_ttl_seconds`. Side-aware
    # (only_per_side) and scoped per-symbol or global. threshold: 0 disables.
    stoploss_guard: {
      threshold: ENV.fetch("STOPLOSS_GUARD_THRESHOLD", "4").to_i,
      lookback_seconds: ENV.fetch("STOPLOSS_GUARD_LOOKBACK_SECONDS", "3600").to_i,
      only_per_side: ENV.fetch("STOPLOSS_GUARD_ONLY_PER_SIDE", "true").to_s.casecmp("true").zero?,
      scope: ENV.fetch("STOPLOSS_GUARD_SCOPE", "symbol"),
      lock_ttl_seconds: ENV.fetch("STOPLOSS_GUARD_LOCK_TTL_SECONDS", "1800").to_i,
      per_symbol: {}
    },

    # MaxDrawdown (issue #401): halt ALL new entries globally once equity falls
    # `ceiling` (fraction) from its peak within `lookback_seconds`, for
    # `lock_ttl_seconds`. Equity-curve drawdown. ceiling: 0 disables.
    max_drawdown: {
      ceiling: ENV.fetch("MAX_DRAWDOWN_CEILING", "0.15").to_f,
      lookback_seconds: ENV.fetch("MAX_DRAWDOWN_LOOKBACK_SECONDS", "86400").to_i,
      lock_ttl_seconds: ENV.fetch("MAX_DRAWDOWN_LOCK_TTL_SECONDS", "1800").to_i
    }
  },

  # API settings
  api_key: ENV["SIGNALS_API_KEY"],
  cors_origins: ENV.fetch("SIGNALS_CORS_ORIGINS", "*").split(","),

  # Logging settings
  log_level: ENV.fetch("REALTIME_SIGNAL_LOG_LEVEL", "info"),
  enable_debug_logging: ENV.fetch("REALTIME_SIGNAL_DEBUG", "false").to_s.casecmp("true").zero?
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
  Rails.logger.info("[RTS] Real-time signals configuration loaded:")
  Rails.logger.info("[RTS]   Evaluation interval: #{config[:evaluation_interval]}s")
  Rails.logger.info("[RTS]   Min confidence: #{config[:min_confidence_threshold]}%")
  Rails.logger.info("[RTS]   Max signals/hour: #{config[:max_signals_per_hour]}")
  Rails.logger.info("[RTS]   Broadcast enabled: #{config[:broadcast_enabled]}")
  Rails.logger.info("[RTS]   Candle aggregation: #{config[:candle_aggregation_enabled]}")
end
