# frozen_string_literal: true

class TradingConfiguration
  class << self
    def current_profile
      TradingProfile.active.order(updated_at: :desc).first
    end

    def signal_equity_usd
      current_profile&.signal_equity_usd&.to_f || env_float("SIGNAL_EQUITY_USD", 10_000.0)
    end

    def min_confidence
      current_profile&.min_confidence&.to_f || env_float("REALTIME_SIGNAL_MIN_CONFIDENCE", 60.0)
    end

    def max_signals_per_hour
      current_profile&.max_signals_per_hour&.to_i || env_int("REALTIME_SIGNAL_MAX_PER_HOUR", 10)
    end

    def evaluation_interval_seconds
      current_profile&.evaluation_interval_seconds&.to_i || env_int("REALTIME_SIGNAL_EVALUATION_INTERVAL", 30)
    end

    def strategy_risk_fraction
      current_profile&.strategy_risk_fraction&.to_f || env_float("STRATEGY_RISK_FRACTION", 0.01)
    end

    def strategy_tp_target
      current_profile&.strategy_tp_target&.to_f || env_float("STRATEGY_TP_TARGET", 0.006)
    end

    def strategy_sl_target
      current_profile&.strategy_sl_target&.to_f || env_float("STRATEGY_SL_TARGET", 0.004)
    end

    private

    def env_float(key, fallback)
      Float(ENV.fetch(key, fallback.to_s))
    rescue ArgumentError, TypeError
      fallback
    end

    def env_int(key, fallback)
      Integer(ENV.fetch(key, fallback.to_s))
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
