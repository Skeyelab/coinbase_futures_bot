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
    # Asset-level suspensions (issue #505), keyed by base currency ("ETH").
    # Contract-keyed suspension degrades silently over time: dated contracts
    # roll monthly, each new month syncs in as a fresh product_id carrying no
    # suspension, and an asset barred on negative-EV grounds becomes tradeable
    # again through a contract that did not exist when the decision was made
    # (observed live: ET-30OCT26-CDE, days after the ETH decision). An asset
    # suspension covers every present AND future contract for that underlying.
    ASSET_STORE_KEY = "asset_suspensions"

    module_function

    # Blocked from NEW entries: explicitly suspended (this contract or its
    # whole asset), or never explicitly enabled. Suspension wins over
    # enablement at both levels — a per-contract enablement cannot punch
    # through an asset-level bar; the asset must be resumed by name.
    def suspended?(symbol)
      return true if explicitly_suspended?(symbol)
      return true if asset_suspended?(symbol)

      !explicitly_enabled?(symbol)
    end

    def enabled?(symbol) = !suspended?(symbol)

    def explicitly_suspended?(symbol)
      all.key?(symbol.to_s)
    end

    def asset_suspended?(symbol)
      asset_suspensions.key?(asset_for(symbol))
    end

    # The underlying an operator's decision is actually about. A contract
    # product_id resolves through the venue prefix map (ET-30OCT26-CDE ->
    # "ETH"); a spot-style eval symbol drops its quote (ETH-USD -> "ETH");
    # a bare asset is itself.
    def asset_for(symbol)
      key = symbol.to_s
      info = Contract.parse_contract_info(key)
      return info[:base_currency] if info

      key.include?("-") ? key.split("-").first : key
    end

    # A bare key with no dash is an asset name, not a product id.
    def asset_key?(symbol)
      !symbol.to_s.include?("-")
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

      asset = asset_for(key)
      asset_entry = asset_suspensions[asset]
      if asset_entry
        return "suspended at the asset level (#{asset}): #{asset_entry["reason"] || "unspecified"} — " \
               "run `bin/futuresbot resume #{asset}` to re-enable the asset"
      end
      return nil if explicitly_enabled?(key)

      "not enabled for trading (ADR 0006 fails closed; no enablement recorded) — " \
        "run `bin/futuresbot resume #{key}` or add it to LIVE_INSTRUMENTS"
    end

    def suspend!(symbol, reason: nil, logger: Rails.logger)
      key = symbol.to_s
      # A bare asset name suspends the ASSET: every contract for that
      # underlying, including months that have not synced yet (#505).
      if asset_key?(key)
        update_asset_store do |entries|
          entries[key] = {
            "reason" => reason,
            "suspended_at" => Time.current.utc.iso8601
          }
        end
        logger.warn("[SymbolSuspension] asset #{key} SUSPENDED — no new entries on any #{key} contract, present or future. Reason: #{reason || "unspecified"}")
        return
      end

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
    # enablement the fail-closed default now requires. A bare asset name lifts
    # the asset-level bar; it does NOT enable any specific contract — those
    # keep their own enablement records.
    def enable!(symbol, reason: nil, logger: Rails.logger)
      key = symbol.to_s
      if asset_key?(key)
        update_asset_store { |entries| entries.delete(key) }
        logger.warn("[SymbolSuspension] asset #{key} suspension lifted. Individual contracts still need their own enablement. Reason: #{reason || "unspecified"}")
        return
      end

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
      (enablements.keys + seeded_symbols).uniq
        .reject { |s| explicitly_suspended?(s) || asset_suspended?(s) }.sort
    end

    # { "SYMBOL" => {"reason" => ..., "suspended_at" => ...}, ... }
    def all = read_store(STORE_KEY)

    # { "ASSET" => {"reason" => ..., "suspended_at" => ...}, ... } (#505)
    def asset_suspensions = read_store(ASSET_STORE_KEY)

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

    def update_asset_store(&) = write_store(ASSET_STORE_KEY, &)

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
