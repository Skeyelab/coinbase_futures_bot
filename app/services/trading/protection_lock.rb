# frozen_string_literal: true

module Trading
  # Durable trading protection locks (issue #397, ADR 0003). By default persisted
  # in bot_runtime_stats (same pattern as TradingHalt / SymbolSuspension) so every
  # process — realtime loop, worker, CLI — sees the same active locks and a lock
  # survives a process restart within its TTL.
  #
  # The backing store is injectable so a backtest can evaluate the SAME protection
  # logic against an in-memory store on a simulated clock, without touching the
  # live bot_runtime_stats state. Pass store: ProtectionLock::MemoryStore.new and
  # an explicit now:.
  #
  # A lock is a plain hash:
  #   scope:      "global" | "symbol"
  #   symbol:     product id (nil for global locks)
  #   side:       "long" | "short" | "both"
  #   source:     the protection that wrote it (e.g. "CooldownPeriod")
  #   reason:     optional human-readable reason
  #   expires_at: ISO8601 timestamp; the lock is ignored once past
  module ProtectionLock
    STORE_KEY = "protection_locks"

    # Live store: durable rows in bot_runtime_stats, shared across processes.
    class DbStore
      def read
        record = BotRuntimeStat.find_by(key: STORE_KEY)
        Array(record&.value)
      end

      def update
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

    # Backtest store: run-local, in-memory. Never written to the DB.
    class MemoryStore
      def initialize
        @locks = []
      end

      def read
        @locks
      end

      def update
        @locks = yield(@locks)
      end
    end

    module_function

    def default_store
      DbStore.new
    end

    def add(scope:, source:, expires_at:, symbol: nil, side: "both", reason: nil, store: default_store)
      lock = {
        "scope" => scope.to_s,
        "symbol" => symbol&.to_s,
        "side" => side.to_s,
        "source" => source.to_s,
        "reason" => reason,
        "expires_at" => expires_at.utc.iso8601
      }
      store.update { |locks| locks + [lock] }
      lock
    end

    # Non-expired locks. Prunes expired locks from the store as a side effect so
    # the store does not grow unbounded.
    def active(now: Time.current, store: default_store)
      pruned = nil
      store.update do |locks|
        pruned = locks.reject { |l| expired?(l, now) }
        pruned
      end
      pruned
    end

    def clear!(store: default_store)
      store.update { |_locks| [] }
    end

    def expired?(lock, now = Time.current)
      expires_at = lock["expires_at"]
      return true if expires_at.blank?

      Time.parse(expires_at) <= now
    end
  end
end
