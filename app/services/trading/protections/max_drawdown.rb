# frozen_string_literal: true

module Trading
  module Protections
    # MaxDrawdown (issue #401, ADR 0003). An equity-drawdown circuit breaker: when
    # the drawdown from the recent equity peak exceeds a ceiling, write a GLOBAL
    # ProtectionLock halting all new entries until it recovers (the lock TTL).
    # Complements — does not replace — the cost-based SymbolCircuitBreakerJob and
    # the manual TradingHalt.
    #
    # Drawdown-from-peak IS the equity-curve drawdown. Pure decision (no DB/clock):
    # the caller supplies peak + current — a rolling durable peak live, the peak
    # within the lookback window from the run's equity_curve in backtest — so the
    # decision is identical in both.
    class MaxDrawdown
      SOURCE = "MaxDrawdown"
      DEFAULT_LOCK_TTL_SECONDS = 1800 # 30m recovery window
      DEFAULT_LOOKBACK_SECONDS = 86_400 # 24h peak window

      # Resolve from config: real_time_signals[:protections][:max_drawdown].
      # Safe default: halt globally for 30m once equity falls 15% from its 24h peak.
      # ceiling: 0 disables.
      def self.from_config
        cfg = Rails.application.config.try(:real_time_signals)&.dig(:protections, :max_drawdown) || {}
        new(
          ceiling: cfg.fetch(:ceiling, 0.15),
          lookback_seconds: cfg.fetch(:lookback_seconds, DEFAULT_LOOKBACK_SECONDS),
          lock_ttl_seconds: cfg.fetch(:lock_ttl_seconds, DEFAULT_LOCK_TTL_SECONDS)
        )
      end

      # lookback_seconds is a hint for callers computing the peak window; the pure
      # decision only needs peak + current.
      attr_reader :lookback_seconds

      def initialize(ceiling:, lookback_seconds: DEFAULT_LOOKBACK_SECONDS, lock_ttl_seconds: DEFAULT_LOCK_TTL_SECONDS)
        @ceiling = ceiling.to_f
        @lookback_seconds = lookback_seconds.to_i
        @lock_ttl_seconds = lock_ttl_seconds.to_i
      end

      def enabled?
        @ceiling.positive?
      end

      # Fractional drop from peak to current, in [0, 1]. 0 at a new high or when
      # the peak is non-positive.
      def drawdown(peak:, current:)
        return 0.0 unless peak && current && peak.to_f.positive?

        dd = (peak.to_f - current.to_f) / peak.to_f
        dd.negative? ? 0.0 : dd
      end

      # Writes a global halt when drawdown exceeds the ceiling. Returns the locks.
      def evaluate(peak:, current:, now: Time.current, store: Trading::ProtectionLock.default_store)
        return [] unless enabled?
        return [] if drawdown(peak: peak, current: current) < @ceiling

        [Trading::ProtectionLock.add(
          scope: "global",
          side: "both",
          source: SOURCE,
          reason: "equity drawdown #{(drawdown(peak: peak, current: current) * 100).round(1)}% >= #{(@ceiling * 100).round(1)}%",
          expires_at: now + @lock_ttl_seconds,
          store: store
        )]
      end
    end
  end
end
