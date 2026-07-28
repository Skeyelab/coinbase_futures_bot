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

      # Writes a global halt when drawdown exceeds the ceiling. Returns the locks
      # it WROTE — empty when the breach is a continuation of one already halted.
      #
      # Idempotent on purpose. A halt is a state, not an event per evaluation
      # cycle. MaxDrawdownMonitor calls this every ~30s and raises a Slack
      # warning per lock returned, so re-adding unconditionally produced an alert
      # every 30 seconds and stacked 12 identical locks for a single condition
      # (observed 2026-07-28). An operator who learns to mute that channel also
      # misses the liquidation-buffer warning that shares it.
      #
      # Returning [] does NOT un-halt anything: the existing lock is still in the
      # store and Protections.blocked? still reports true. This suppresses the
      # duplicate record and the duplicate alarm, not the protection. Once the
      # lock expires, a still-breaching equity curve halts and alerts afresh.
      def evaluate(peak:, current:, now: Time.current, store: Trading::ProtectionLock.default_store)
        return [] unless enabled?
        return [] if drawdown(peak: peak, current: current) < @ceiling
        return [] if already_halted?(now: now, store: store)

        [Trading::ProtectionLock.add(
          scope: "global",
          side: "both",
          source: SOURCE,
          reason: "equity drawdown #{(drawdown(peak: peak, current: current) * 100).round(1)}% >= #{(@ceiling * 100).round(1)}%",
          expires_at: now + @lock_ttl_seconds,
          store: store
        )]
      end

      # True when a global halt from THIS guard is already in force. Scoped to
      # SOURCE so an unrelated protection's lock never suppresses a drawdown
      # halt that has not yet been raised.
      def already_halted?(now:, store:)
        Trading::ProtectionLock.active(now: now, store: store)
          .any? { |lock| lock["source"] == SOURCE }
      end
    end
  end
end
