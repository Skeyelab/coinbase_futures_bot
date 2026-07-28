# frozen_string_literal: true

module Trading
  # LiquidationBuffer (issue #399, ADR 0003). Exits a leveraged position BEFORE it
  # reaches liquidation, capping the worst case a take-profit-only scalp would
  # otherwise leave open. Pure math — no DB, no clock — so it is table-testable.
  #
  # Isolated-margin liquidation price: with initial-margin fraction im = 1/leverage
  # and maintenance-margin fraction mm, a position is liquidated once the loss
  # reaches (im - mm) of notional, i.e. a price move of (im - mm):
  #   long:  liq = entry * (1 - (im - mm))   (price falls to liq)
  #   short: liq = entry * (1 + (im - mm))   (price rises to liq)
  #
  # Buffered exit sits `buffer` of the entry→liq distance on the SAFE side of liq
  # (issue formula: liq ± buffer * |entry - liq|, + for long, - for short), so the
  # bot closes before the exchange forces liquidation.
  #
  # Leverage comes from the contract's REAL margin rate where we have it. It used
  # to come from DEFAULT_LEVERAGE = 10.0 because nothing stored margin, which is
  # fine while every instrument is ~10x and dangerous the moment one is not: on
  # PAU (gold perp, 5% intraday = 20x) the assumed-10x buffered exit sat at ~9.0%
  # adverse while real liquidation is at ~4.5%. The rail was behind the cliff.
  #
  # Margin is per-side and per-window (see the AddMarginRatesToContracts
  # migration). We arm on the INTRADAY rate because it is the lower of the two,
  # which puts liquidation closest to entry — the conservative assumption for a
  # position of unknown horizon. A position actually held into the overnight
  # window has MORE margin posted and so liquidates further away; exiting on the
  # intraday distance is early there, never late.
  #
  # When a contract has no stored margin, this refuses to arm rather than
  # guessing. An unarmed buffer protects nothing, but a buffer calibrated on a
  # wrong constant protects nothing AND reads as protection.
  class LiquidationBuffer
    DEFAULT_MAINTENANCE_MARGIN_RATE = 0.005 # 0.5%

    # Resolve from config, with the contract's real per-side margin preferred over
    # any configured leverage. Default buffer 0.05 per ADR 0003.
    #   real_time_signals[:liquidation_buffer] =
    #     { buffer: 0.05, leverage: 10.0, maintenance_margin_rate: 0.005,
    #       per_symbol: { "SYM" => { buffer:, leverage:, maintenance_margin_rate: } } }
    # Configured leverage is now only a FALLBACK for contracts we have no margin
    # for; it no longer silently overrides reality.
    def self.from_config(symbol: nil)
      cfg = Rails.application.config.try(:real_time_signals)&.dig(:liquidation_buffer) || {}
      merged = cfg.merge(cfg.dig(:per_symbol, symbol) || {})
      new(
        buffer: merged.fetch(:buffer, 0.05),
        maintenance_margin_rate: merged.fetch(:maintenance_margin_rate, DEFAULT_MAINTENANCE_MARGIN_RATE),
        leverage: merged[:leverage],
        symbol: symbol,
        contract_leverage: contract_leverage_for(symbol)
      )
    end

    # {long: Float, short: Float} from the contract's intraday margin rates, or
    # {} when the contract is unknown or predates the margin columns.
    def self.contract_leverage_for(symbol)
      return {} if symbol.blank?

      contract = Contract.find_by(product_id: symbol)
      return {} unless contract

      {
        long: leverage_from_rate(contract.intraday_margin_rate_long),
        short: leverage_from_rate(contract.intraday_margin_rate_short)
      }.compact
    rescue => e
      # Never let a margin lookup break the tick path; an unresolved rate simply
      # leaves the buffer unarmed, which is the fail-closed direction.
      Rails.logger.error("[LiquidationBuffer] margin lookup failed for #{symbol}: #{e.class}: #{e.message}")
      {}
    end

    def self.leverage_from_rate(rate)
      r = rate.to_f
      return nil unless r.positive?

      1.0 / r
    end

    attr_reader :buffer

    def initialize(buffer: 0.05, maintenance_margin_rate: DEFAULT_MAINTENANCE_MARGIN_RATE,
      leverage: nil, symbol: nil, contract_leverage: {})
      @buffer = buffer.to_f
      @mm = maintenance_margin_rate.to_f
      @default_leverage = leverage
      @symbol = symbol
      @contract_leverage = contract_leverage || {}
    end

    def enabled?
      @buffer.positive?
    end

    # True only when this symbol/side has a leverage we actually believe.
    def armed?(side)
      enabled? && resolve_leverage(side, nil).to_f.positive?
    end

    def liquidation_price(entry_price:, side:, leverage: nil)
      lev = resolve_leverage(side, leverage)
      return nil unless usable?(entry_price, lev)

      loss_to_liq = (1.0 / lev.to_f) - @mm # im - mm
      long?(side) ? entry_price * (1 - loss_to_liq) : entry_price * (1 + loss_to_liq)
    end

    def buffered_exit_price(entry_price:, side:, leverage: nil)
      liq = liquidation_price(entry_price: entry_price, side: side, leverage: leverage)
      return nil if liq.nil?

      pad = @buffer * (entry_price - liq).abs
      long?(side) ? liq + pad : liq - pad
    end

    # True once current_price has reached/passed the buffered exit on the losing
    # side (long: fallen to it; short: risen to it). Returns false — never a
    # spurious close — when leverage is unknown, and says so once per symbol.
    def breached?(entry_price:, side:, current_price:, leverage: nil)
      return false unless enabled?
      return false if current_price.nil? || !current_price.to_f.positive?

      unless resolve_leverage(side, leverage).to_f.positive?
        warn_unarmed(side)
        return false
      end

      exit_price = buffered_exit_price(entry_price: entry_price, side: side, leverage: leverage)
      return false if exit_price.nil?

      long?(side) ? current_price <= exit_price : current_price >= exit_price
    end

    private

    # Explicit argument wins (table tests and callers that know better), then the
    # contract's real per-side margin, then configured leverage as a fallback.
    def resolve_leverage(side, explicit)
      return explicit if explicit

      @contract_leverage[long?(side) ? :long : :short] || @default_leverage
    end

    def warn_unarmed(side)
      @warned ||= {}
      key = long?(side) ? :long : :short
      return if @warned[key]

      @warned[key] = true
      Rails.logger.warn(
        "[LiquidationBuffer] NOT ARMED for #{@symbol || "unknown symbol"} (#{key}): no margin rate " \
        "stored and no leverage configured. No pre-liquidation exit will fire. " \
        "Ingest products to populate contracts.intraday_margin_rate_*, or set " \
        "real_time_signals[:liquidation_buffer][:per_symbol]."
      )
    end

    def usable?(entry_price, leverage)
      entry_price&.to_f&.positive? && leverage&.to_f&.positive?
    end

    # SideNormalizer, not a bare == "long": position sides arrive as "long"/"LONG"
    # but also "buy"/"BUY", and treating a "buy" as a short computed the
    # liquidation price on the wrong side of entry entirely.
    def long?(side)
      SideNormalizer.signal(side) == "long"
    end
  end
end
