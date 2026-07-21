# frozen_string_literal: true

module Trading
  # Per-symbol trading suspension (issue #371). Durable in bot_runtime_stats
  # (same pattern as TradingHalt/DryRun) so every process — realtime loop,
  # worker, CLI — sees the same state. Suspension only blocks NEW entries;
  # exits/position management continue so a suspended symbol can still close.
  #
  # Set manually (operator) or by SymbolCircuitBreakerJob when a symbol's
  # trailing gross edge stops covering its round-trip costs. Resume is always
  # manual: a symbol re-earns its slot, it doesn't drift back in.
  module SymbolSuspension
    STORE_KEY = "symbol_suspensions"

    module_function

    def suspended?(symbol)
      all.key?(symbol.to_s)
    end

    def suspend!(symbol, reason: nil, logger: Rails.logger)
      update_store do |entries|
        entries[symbol.to_s] = {
          "reason" => reason,
          "suspended_at" => Time.current.utc.iso8601
        }
      end
      logger.warn("[SymbolSuspension] #{symbol} SUSPENDED — no new entries. Reason: #{reason || "unspecified"}")
    end

    def resume!(symbol, logger: Rails.logger)
      update_store { |entries| entries.delete(symbol.to_s) }
      logger.warn("[SymbolSuspension] #{symbol} resumed")
    end

    # { "SYMBOL" => {"reason" => ..., "suspended_at" => ...}, ... }
    def all
      record = BotRuntimeStat.find_by(key: STORE_KEY)
      (record&.value || {}).to_h
    end

    def update_store
      record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
      entries = (record.value || {}).to_h
      yield entries
      record.value = entries
      record.recorded_at = Time.current.utc
      record.save!
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
