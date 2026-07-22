# frozen_string_literal: true

module Trading
  # Durable trading protection locks (issue #397, ADR 0003). Persisted in
  # bot_runtime_stats (same pattern as TradingHalt / SymbolSuspension) so every
  # process — realtime loop, worker, CLI, backtest — sees the same active locks
  # and a lock survives a process restart within its TTL.
  #
  # A lock is a plain hash:
  #   scope:      "global" | "symbol"
  #   symbol:     product id (nil for global locks)
  #   side:       "long" | "short" | "both"
  #   source:     the protection that wrote it (e.g. "CooldownPeriod")
  #   reason:     optional human-readable reason
  #   expires_at: ISO8601 timestamp; the lock is ignored once past
  #
  # Locks auto-expire on read (past-expiry locks are pruned), so nothing lingers
  # forever. Matching a lock against a candidate (symbol, side) lives in
  # Trading::Protections — this class is storage + expiry only.
  module ProtectionLock
    STORE_KEY = "protection_locks"

    module_function

    def add(scope:, source:, expires_at:, symbol: nil, side: "both", reason: nil)
      lock = {
        "scope" => scope.to_s,
        "symbol" => symbol&.to_s,
        "side" => side.to_s,
        "source" => source.to_s,
        "reason" => reason,
        "expires_at" => expires_at.utc.iso8601
      }
      update_store { |locks| locks.push(lock) }
      lock
    end

    # Non-expired locks. Prunes expired locks from the store as a side effect so
    # the store does not grow unbounded.
    def active(now: Time.current)
      pruned = nil
      update_store do |locks|
        pruned = locks.reject { |l| expired?(l, now) }
        pruned
      end
      pruned
    end

    def clear!
      update_store { |_locks| [] }
    end

    def expired?(lock, now = Time.current)
      expires_at = lock["expires_at"]
      return true if expires_at.blank?

      Time.parse(expires_at) <= now
    end

    def update_store
      record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
      locks = Array(record.value)
      result = yield(locks)
      record.value = result
      record.recorded_at = Time.current.utc
      record.save!
      result
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
