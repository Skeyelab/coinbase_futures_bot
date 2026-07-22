# frozen_string_literal: true

module Trading
  # Trading protections (issue #397, ADR 0003). Evaluates the active
  # ProtectionLocks against a candidate (symbol, side) entry and answers whether
  # the entry is currently blocked. This is the single seam consulted by the
  # realtime evaluator and the backtest before an entry is accepted.
  #
  # Individual protections (CooldownPeriod, StoplossGuard, MaxDrawdown, ...) are
  # small objects that WRITE locks via Trading::ProtectionLock; this module is
  # the READ side that composes them. New protections drop in behind here without
  # touching the evaluator.
  #
  # Lock matching:
  #   scope "global"  -> matches every symbol
  #   scope "symbol"  -> matches only its own symbol
  #   side  "both"    -> matches either candidate side
  #   side  "long"/"short" -> matches only that candidate side
  module Protections
    module_function

    def blocked?(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      matching_lock(symbol: symbol, side: side, now: now, store: store).present?
    end

    # Human-readable reason for the blocking lock, or nil if not blocked.
    def block_reason(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      lock = matching_lock(symbol: symbol, side: side, now: now, store: store)
      return nil unless lock

      base = lock["source"].to_s
      reason = lock["reason"].to_s
      reason.present? ? "#{base}: #{reason}" : base
    end

    def matching_lock(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      Trading::ProtectionLock.active(now: now, store: store)
        .find { |lock| matches?(lock, symbol: symbol, side: side) }
    end

    def matches?(lock, symbol:, side:)
      scope_matches?(lock, symbol) && side_matches?(lock, side)
    end

    def scope_matches?(lock, symbol)
      return true if lock["scope"] == "global"

      lock["symbol"].to_s == symbol.to_s
    end

    def side_matches?(lock, side)
      lock_side = lock["side"].to_s
      lock_side == "both" || lock_side == side.to_s
    end
  end
end
