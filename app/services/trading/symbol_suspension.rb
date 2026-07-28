# frozen_string_literal: true

module Trading
  # Per-symbol trading permission (issue #371, ADR 0006 decisions 4 and 5).
  # Durable in bot_runtime_stats (same pattern as TradingHalt/DryRun) so every
  # process — realtime loop, worker, CLI — sees the same state. A block only
  # stops NEW entries; exits/position management continue so a blocked symbol
  # can still close.
  #
  # FAIL CLOSED (ADR 0006). This store used to answer one question — "has
  # something suspended this symbol?" — against a store that starts EMPTY, so
  # the answer for every newly-ingested product was "no, trade it". Adding one
  # line to Contract::PREFIX_TO_BASE_CURRENCY put a new instrument on the order
  # path with no decision recorded anywhere, and contract.rb's claim that PAU
  # "stays SymbolSuspension-suspended" was aspirational rather than true.
  #
  # There are now TWO facts, not one:
  #
  #   enablement — an explicit, recorded "this symbol may trade", from an
  #                operator (`bin/futuresbot resume SYMBOL`) or from the
  #                LIVE_INSTRUMENTS deploy seed.
  #   suspension — an explicit, recorded "this symbol may NOT trade", from an
  #                operator or from SymbolCircuitBreakerJob.
  #
  # `suspended?` is now the absence of the first OR the presence of the second.
  # Suspension stays authoritative over enablement so a circuit-breaker trip
  # cannot be undone by a stale enablement record — resume is always deliberate,
  # a symbol re-earns its slot rather than drifting back in.
  #
  # The recovery path out of a fail-closed block is `bin/futuresbot resume
  # SYMBOL`, and `block_reason` says so verbatim: a control nobody can find is
  # not a control.
  module SymbolSuspension
    STORE_KEY = "symbol_suspensions"
    ENABLEMENT_KEY = "symbol_enablements"

    module_function

    # Blocked from NEW entries: either never explicitly enabled, or explicitly
    # suspended. Explicit suspension wins.
    def suspended?(symbol)
      return true if explicitly_suspended?(symbol)

      !explicitly_enabled?(symbol)
    end

    def enabled?(symbol) = !suspended?(symbol)

    def explicitly_suspended?(symbol)
      all.key?(symbol.to_s)
    end

    def explicitly_enabled?(symbol)
      key = symbol.to_s
      return false if key.empty?

      enablements.key?(key) || seeded_symbols.include?(key)
    end

    # Why this symbol cannot open a position, phrased so the operator reading it
    # in a log knows the exact command that ends the block.
    def block_reason(symbol)
      key = symbol.to_s
      entry = all[key]
      return "suspended: #{entry["reason"] || "unspecified"} — run `bin/futuresbot resume #{key}` to re-enable" if entry
      return nil if explicitly_enabled?(key)

      "not enabled for trading (ADR 0006 fails closed; no enablement recorded) — " \
        "run `bin/futuresbot resume #{key}` or add it to LIVE_INSTRUMENTS"
    end

    def suspend!(symbol, reason: nil, logger: Rails.logger)
      key = symbol.to_s
      update_store do |entries|
        entries[key] = {
          "reason" => reason,
          "suspended_at" => Time.current.utc.iso8601
        }
      end
      # Revoking the enablement is what makes resume a decision rather than a
      # formality: deleting the suspension alone would leave a symbol that the
      # breaker just tripped instantly tradeable again.
      update_enablements { |entries| entries.delete(key) }
      logger.warn("[SymbolSuspension] #{key} SUSPENDED — no new entries. Reason: #{reason || "unspecified"}")
    end

    # The inverse of suspend!: clears any suspension AND records the explicit
    # enablement the fail-closed default now requires.
    def enable!(symbol, reason: nil, logger: Rails.logger)
      key = symbol.to_s
      update_store { |entries| entries.delete(key) }
      update_enablements do |entries|
        entries[key] = {
          "reason" => reason,
          "enabled_at" => Time.current.utc.iso8601
        }
      end
      logger.warn("[SymbolSuspension] #{key} ENABLED for trading. Reason: #{reason || "unspecified"}")
    end

    def resume!(symbol, reason: nil, logger: Rails.logger)
      enable!(symbol, reason: reason, logger: logger)
    end

    # Every symbol currently permitted to open a position.
    def live_symbols
      (enablements.keys + seeded_symbols).uniq.reject { |s| explicitly_suspended?(s) }.sort
    end

    # { "SYMBOL" => {"reason" => ..., "suspended_at" => ...}, ... }
    def all = read_store(STORE_KEY)

    # { "SYMBOL" => {"reason" => ..., "enabled_at" => ...}, ... }
    def enablements = read_store(ENABLEMENT_KEY)

    # Declarative deploy seed so a fresh database is not an outage that only a
    # Rails console can end. Read every call — ENV is set per-process at boot
    # and specs stub it per example.
    def seeded_symbols
      ENV.fetch("LIVE_INSTRUMENTS", "").split(",").map(&:strip).reject(&:empty?)
    end

    def read_store(key)
      record = BotRuntimeStat.find_by(key: key)
      (record&.value || {}).to_h
    end

    def update_store(&) = write_store(STORE_KEY, &)

    def update_enablements(&) = write_store(ENABLEMENT_KEY, &)

    def write_store(key)
      record = BotRuntimeStat.find_or_initialize_by(key: key)
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
