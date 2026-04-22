# frozen_string_literal: true

class TradingConfiguration
  class << self
    def current_profile
      @current_profile ||= TradingProfile.active.order(updated_at: :desc).first
    end

    def reset_profile_cache!
      @current_profile = nil
    end

    def signal_equity_usd
      profile_float(:signal_equity_usd) || env_float("SIGNAL_EQUITY_USD", 10_000.0)
    end

    def min_confidence
      profile_float(:min_confidence) || env_float("REALTIME_SIGNAL_MIN_CONFIDENCE", 60.0)
    end

    def max_signals_per_hour
      profile_int(:max_signals_per_hour) || env_int("REALTIME_SIGNAL_MAX_PER_HOUR", 10)
    end

    def evaluation_interval_seconds
      profile_int(:evaluation_interval_seconds) || env_int("REALTIME_SIGNAL_EVALUATION_INTERVAL", 30)
    end

    def strategy_risk_fraction
      profile_float(:strategy_risk_fraction) || env_float("STRATEGY_RISK_FRACTION", 0.01)
    end

    def strategy_tp_target
      profile_float(:strategy_tp_target) || env_float("STRATEGY_TP_TARGET", 0.006)
    end

    def strategy_sl_target
      profile_float(:strategy_sl_target) || env_float("STRATEGY_SL_TARGET", 0.004)
    end

    private

    def profile_float(attribute)
      value = current_profile&.public_send(attribute)
      return if value.nil?

      coerce_float(value, nil)
    end

    def profile_int(attribute)
      value = current_profile&.public_send(attribute)
      return if value.nil?

      coerce_int(value, nil)
    end

    def env_float(key, fallback)
      coerce_float(ENV.fetch(key, fallback.to_s), fallback)
    end

    def env_int(key, fallback)
      coerce_int(ENV.fetch(key, fallback.to_s), fallback)
    end

    def coerce_float(value, fallback)
      Float(value)
    rescue ArgumentError, TypeError
      fallback
    end

    def coerce_int(value, fallback)
      Integer(value)
    rescue ArgumentError, TypeError
      fallback
    end

  end
end
