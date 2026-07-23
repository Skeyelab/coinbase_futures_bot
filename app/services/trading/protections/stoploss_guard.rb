# frozen_string_literal: true

module Trading
  module Protections
    # StoplossGuard (issue #400, ADR 0003). Halts new entries after a cluster of
    # losing exits within a lookback window — a bad-regime circuit breaker ported
    # from freqtrade. Built on the #397 ProtectionLock substrate.
    #
    # Side-aware: with only_per_side, longs and shorts are counted and locked
    # independently (a regime punishing one direction must not block the other).
    # Scope is per-symbol or global.
    #
    # Source-agnostic: the caller passes recent LOSING exits as
    # [{side: "long"|"short", at: Time}, ...] — from a Position query live, or the
    # completed-trade list in a backtest — so the decision is identical in both.
    # ("stop-out" = a losing close; Position close reason isn't persisted, and a
    # cluster of losses is exactly the signal the guard exists to catch.)
    class StoplossGuard
      SOURCE = "StoplossGuard"
      DEFAULT_LOCK_TTL_SECONDS = 1800 # 30m

      # Resolve from config: real_time_signals[:protections][:stoploss_guard] with
      # per-symbol overrides. Safe defaults halt a side for 30m after 4 losing
      # exits in an hour; set threshold: 0 to disable.
      def self.from_config(symbol: nil)
        cfg = Rails.application.config.try(:real_time_signals)&.dig(:protections, :stoploss_guard) || {}
        merged = cfg.merge(cfg.dig(:per_symbol, symbol) || {})
        new(
          threshold: merged.fetch(:threshold, 4),
          lookback_seconds: merged.fetch(:lookback_seconds, 3600),
          only_per_side: merged.fetch(:only_per_side, true),
          scope: merged.fetch(:scope, "symbol"),
          lock_ttl_seconds: merged.fetch(:lock_ttl_seconds, DEFAULT_LOCK_TTL_SECONDS)
        )
      end

      def initialize(threshold:, lookback_seconds:, only_per_side: true, scope: "symbol",
        lock_ttl_seconds: DEFAULT_LOCK_TTL_SECONDS)
        @threshold = threshold.to_i
        @lookback_seconds = lookback_seconds.to_i
        @only_per_side = only_per_side
        @scope = scope.to_s
        @lock_ttl_seconds = lock_ttl_seconds.to_i
      end

      def enabled?
        @threshold.positive? && @lookback_seconds.positive?
      end

      # Count recent losing exits and, if any side (or the combined total) meets
      # the threshold, write a ProtectionLock. Returns the locks written.
      def evaluate(symbol:, exits:, now: Time.current, store: Trading::ProtectionLock.default_store)
        return [] unless enabled?

        recent = exits.select { |e| e[:at] && e[:at] > now - @lookback_seconds }
        locks = []

        if @only_per_side
          %w[long short].each do |side|
            next if recent.count { |e| e[:side].to_s == side } < @threshold

            locks << write_lock(symbol: symbol, side: side, now: now, store: store)
          end
        elsif recent.size >= @threshold
          locks << write_lock(symbol: symbol, side: "both", now: now, store: store)
        end

        locks
      end

      private

      def write_lock(symbol:, side:, now:, store:)
        Trading::ProtectionLock.add(
          scope: @scope,
          symbol: (@scope == "global") ? nil : symbol,
          side: side,
          source: SOURCE,
          reason: "#{@threshold}+ losing exits in #{@lookback_seconds / 60}m",
          expires_at: now + @lock_ttl_seconds,
          store: store
        )
      end
    end
  end
end
