# frozen_string_literal: true

module Strategy
  class Pullback1h
    DEFAULTS = {
      maker_fee: 0.0005,
      slippage: 0.0002,
      tp_margin: 0.001,
      tp_target: 0.006,
      sl_target: 0.004
    }.freeze

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    # Given recent candles, return a potential order: { side:, price:, quantity:, tp:, sl: }
    def signal(candles:, symbol:, equity_usd: 1000.0)
      return nil if candles.size < 200

      closes = candles.map { |c| c.close.to_f }
      ema20 = ema(closes, 20)
      ema200 = ema(closes, 200)
      last = candles.last

      uptrend = last.close.to_f > ema200
      pullback = last.low.to_f <= ema20 && last.close.to_f >= ema20
      return nil unless uptrend && pullback

      entry = last.close.to_f
      be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:maker_fee], slippage_rate: @config[:slippage])
      tp = [ entry * (1.0 + @config[:tp_target]), be * (1.0 + @config[:tp_margin]) ].max
      sl = entry * (1.0 - @config[:sl_target])

      qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: 0.005)

      {
        side: :buy,
        price: entry,
        quantity: qty,
        tp: tp,
        sl: sl
      }
    end

    private

    def ema(values, period)
      k = 2.0 / (period + 1)
      ema = values.first
      values.each do |v|
        ema = v * k + ema * (1 - k)
      end
      ema
    end

    def position_size(equity_usd:, entry:, sl:, risk_fraction: 0.005)
      risk_per_unit = (entry - sl).abs
      return 0 if risk_per_unit <= 0
      risk_budget = equity_usd.to_f * risk_fraction.to_f
      (risk_budget / risk_per_unit).floor(6)
    end
  end
end