# frozen_string_literal: true

module Trading
  # Single builder for LIVE-configured strategies. The evaluator, calibration,
  # the backtest engine, and signal jobs must all construct strategies the same
  # way, or offline results stop describing online behavior (drift audit
  # 2026-07-21: calibration tuned a DEFAULTS-configured twin with a different
  # trend filter than live).
  #
  # for_symbol is THE declarative-selection resolution site (issue #303):
  # RealTimeSignalEvaluator, RapidSignalEvaluationJob and GenerateSignalsJob
  # all resolve through it. RSE once bypassed the factory and silently traded
  # hardcoded 40/30bps — per-caller resolution is the #479/#504 bug class.
  module StrategyFactory
    UnknownStrategyError = Class.new(StandardError)

    # The strategy registry (issue #303 acceptance): names a config entry may
    # use, mapped to the class the factory will build.
    REGISTRY = {
      "MultiTimeframeSignal" => "Strategy::MultiTimeframeSignal",
      "FundingSkewContrarian" => "Strategy::FundingSkewContrarian"
    }.freeze

    module_function

    def registry = REGISTRY

    # Resolve the strategy for a symbol from config/strategy_selection.yml.
    # Unconfigured symbols get the same live MultiTimeframeSignal as
    # `multi_timeframe` (zero behavior change). Overrides are caller knobs —
    # the rapid path's shorter min-candle requirements and real contract
    # notional — and win over selection params.
    def for_symbol(symbol, profile: nil, **overrides)
      selection_drift_alarm
      selection = Trading::StrategySelection.for_symbol(symbol)

      case selection.strategy_name
      when "MultiTimeframeSignal"
        multi_timeframe(
          profile: profile || TradingProfile.effective(symbol: symbol),
          **selection.params.merge(overrides)
        )
      when "FundingSkewContrarian"
        funding_skew(**selection.params.merge(overrides))
      else
        raise UnknownStrategyError,
          "strategy_selection.yml names unknown strategy #{selection.strategy_name.inspect} " \
          "for #{symbol} (known: #{REGISTRY.keys.join(", ")})"
      end
    end

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

    def funding_skew(**config)
      Strategy::FundingSkewContrarian.new(config)
    end

    def live_config
      Rails.application.config.real_time_signals[:strategies]["MultiTimeframeSignal"]
    end

    # Freeze discipline (#483/#376): a strategy-selection config change while
    # a calibration freeze is active invalidates the gate-2a evidence window.
    # Loud, once per distinct drift — critical Slack alert + error log — on
    # the resolution path itself, so it cannot be missed while trading runs.
    def selection_drift_alarm
      drift = Trading::CalibrationFreeze.strategy_selection_drift
      return if drift.nil? || @selection_drift_alerted == drift

      @selection_drift_alerted = drift
      Rails.logger.error(
        "[StrategyFactory] strategy selection config changed while calibration freeze " \
        "is active — the gate-2a sample is at risk. #{drift.inspect}"
      )
      SlackNotificationService.alert(
        "critical",
        "Strategy selection changed under calibration freeze",
        drift.merge(action: "revert config/strategy_selection.yml or restart the evidence window")
      )
    end
  end
end
