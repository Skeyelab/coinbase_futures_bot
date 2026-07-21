# frozen_string_literal: true

module Trading
  # Single builder for the LIVE-configured MultiTimeframeSignal. The
  # evaluator, calibration, the backtest engine, and signal jobs must all
  # construct the strategy the same way, or offline results stop describing
  # online behavior (drift audit 2026-07-21: calibration tuned a
  # DEFAULTS-configured twin with a different trend filter than live).
  module StrategyFactory
    module_function

    # profile supplies the tunable/risk knobs (tp/sl/risk/position sizes);
    # the real_time_signals initializer supplies structure (EMA periods,
    # min candle counts, contract sizing). Explicit overrides win — used for
    # calibration candidates (tp/sl) and backtest mode (resolve_symbols).
    def multi_timeframe(profile: TradingProfile.effective, **overrides)
      cfg = live_config
      Strategy::MultiTimeframeSignal.new({
        ema_1h_short: cfg[:ema_1h_short],
        ema_1h_long: cfg[:ema_1h_long],
        ema_15m: cfg[:ema_15m],
        ema_5m: cfg[:ema_5m],
        ema_1m: cfg[:ema_1m],
        min_1h_candles: cfg[:min_1h_candles],
        min_15m_candles: cfg[:min_15m_candles],
        min_5m_candles: cfg[:min_5m_candles],
        min_1m_candles: cfg[:min_1m_candles],
        tp_target: profile.tp_target.to_f,
        sl_target: profile.sl_target.to_f,
        risk_fraction: profile.risk_fraction.to_f,
        contract_size_usd: cfg[:contract_size_usd],
        max_position_size: profile.max_position_size,
        min_position_size: profile.min_position_size
      }.merge(overrides))
    end

    def live_config
      Rails.application.config.real_time_signals[:strategies]["MultiTimeframeSignal"]
    end
  end
end
