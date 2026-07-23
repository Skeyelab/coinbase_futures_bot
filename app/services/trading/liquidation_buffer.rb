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
  # Real per-position leverage / per-contract maintenance margin are not stored
  # (the rest of the margin code works on assumptions too); callers pass the best
  # available leverage and the configured mm rate.
  class LiquidationBuffer
    DEFAULT_MAINTENANCE_MARGIN_RATE = 0.005 # 0.5%
    DEFAULT_LEVERAGE = 10.0 # matches the codebase's ~10% margin assumption

    # Resolve from config: buffer/leverage/maintenance rate with per-symbol
    # overrides. Default buffer 0.05 per ADR 0003. Positions carry no real
    # leverage, so an assumed default leverage is used (documented gap) until real
    # per-position leverage is threaded through.
    #   real_time_signals[:liquidation_buffer] =
    #     { buffer: 0.05, leverage: 10.0, maintenance_margin_rate: 0.005,
    #       per_symbol: { "SYM" => { buffer:, leverage:, maintenance_margin_rate: } } }
    def self.from_config(symbol: nil)
      cfg = Rails.application.config.try(:real_time_signals)&.dig(:liquidation_buffer) || {}
      merged = cfg.merge(cfg.dig(:per_symbol, symbol) || {})
      new(
        buffer: merged.fetch(:buffer, 0.05),
        maintenance_margin_rate: merged.fetch(:maintenance_margin_rate, DEFAULT_MAINTENANCE_MARGIN_RATE),
        leverage: merged.fetch(:leverage, DEFAULT_LEVERAGE)
      )
    end

    def initialize(buffer: 0.05, maintenance_margin_rate: DEFAULT_MAINTENANCE_MARGIN_RATE,
      leverage: DEFAULT_LEVERAGE)
      @buffer = buffer.to_f
      @mm = maintenance_margin_rate.to_f
      @default_leverage = leverage
    end

    def enabled?
      @buffer.positive?
    end

    def liquidation_price(entry_price:, side:, leverage: @default_leverage)
      return nil unless usable?(entry_price, leverage)

      loss_to_liq = (1.0 / leverage.to_f) - @mm # im - mm
      long?(side) ? entry_price * (1 - loss_to_liq) : entry_price * (1 + loss_to_liq)
    end

    def buffered_exit_price(entry_price:, side:, leverage: @default_leverage)
      liq = liquidation_price(entry_price: entry_price, side: side, leverage: leverage)
      return nil if liq.nil?

      pad = @buffer * (entry_price - liq).abs
      long?(side) ? liq + pad : liq - pad
    end

    # True once current_price has reached/passed the buffered exit on the losing
    # side (long: fallen to it; short: risen to it).
    def breached?(entry_price:, side:, current_price:, leverage: @default_leverage)
      return false unless enabled?
      return false if current_price.nil? || !current_price.to_f.positive?

      exit_price = buffered_exit_price(entry_price: entry_price, side: side, leverage: leverage)
      return false if exit_price.nil?

      long?(side) ? current_price <= exit_price : current_price >= exit_price
    end

    private

    def usable?(entry_price, leverage)
      entry_price&.to_f&.positive? && leverage&.to_f&.positive?
    end

    def long?(side)
      side.to_s.downcase == "long"
    end
  end
end
