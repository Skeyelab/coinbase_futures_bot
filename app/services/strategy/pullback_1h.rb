# frozen_string_literal: true

module Strategy
  class Pullback1h
    DEFAULTS = {
      fee_rate: nil, # resolved to CostModel.taker_fee_rate in initialize
      slippage: 0.0002,
      tp_margin: 0.001,
      tp_target: 0.006,
      sl_target: 0.004,
      min_candles: 50,  # Reduced from 200 to work with 7-day data
      ema_short: 12,    # Shorter EMA for faster signals
      ema_long: 50      # Shorter long EMA for current data
    }.freeze

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
      @config[:fee_rate] ||= @config[:maker_fee] || CostModel.taker_fee_rate
    end

    # Given recent candles, return a potential order: { side:, price:, quantity:, tp:, sl: }
    def signal(candles:, symbol:, equity_usd: 1000.0)
      return nil if candles.size < @config[:min_candles]

      closes = candles.map { |c| c.close.to_f }
      ema_short = Signals::Indicators.ema(closes, @config[:ema_short])
      ema_long = Signals::Indicators.ema(closes, @config[:ema_long])
      return nil if ema_short.nil? || ema_long.nil?

      last = candles.last

      # Trend analysis
      uptrend = last.close.to_f > ema_long
      pullback = ema_short.between?(last.low.to_f, last.close.to_f)

      # Additional confirmation: volume and momentum
      volume_confirmation = volume_increasing?(candles)
      momentum_confirmation = momentum_positive?(closes)

      return nil unless uptrend && pullback && volume_confirmation && momentum_confirmation

      entry = last.close.to_f
      be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:fee_rate], slippage_rate: @config[:slippage])
      tp = [entry * (1.0 + @config[:tp_target]), be * (1.0 + @config[:tp_margin])].max
      sl = entry * (1.0 - @config[:sl_target])

      qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: 0.005)

      {
        side: :long,
        price: entry,
        quantity: qty,
        tp: tp,
        sl: sl,
        confidence: calculate_confidence(candles, ema_short, ema_long)
      }
    end

    private

    def position_size(equity_usd:, entry:, sl:, risk_fraction: 0.005)
      risk_per_unit = (entry - sl).abs
      return 0 if risk_per_unit <= 0
      risk_budget = equity_usd.to_f * risk_fraction.to_f
      (risk_budget / risk_per_unit).floor(6)
    end

    def volume_increasing?(candles)
      return false if candles.size < 3

      recent_volumes = candles.last(3).map { |c| c.volume.to_f }
      recent_volumes.last > recent_volumes.first
    end

    def momentum_positive?(closes)
      return false if closes.size < 5

      recent_closes = closes.last(5)
      recent_closes.last > recent_closes.first
    end

    def calculate_confidence(candles, ema_short, ema_long)
      # Calculate confidence based on trend strength and pullback quality
      trend_strength = (candles.last.close.to_f - ema_long).abs / ema_long
      pullback_quality = (ema_short - candles.last.low.to_f).abs / ema_short

      confidence = (trend_strength * 0.6 + pullback_quality * 0.4) * 100
      [confidence, 100].min.round(1)
    end
  end
end
