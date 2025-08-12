# frozen_string_literal: true

module Strategy
  # Multi-timeframe signal using 1h trend filter and 15m entry trigger.
  # - 1h: determine dominant trend via EMAs
  # - 15m: enter on pullback-and-reclaim (trend-following) or rejection (short)
  # Returns order-like hash or nil when no setup.
  class MultiTimeframeSignal
    DEFAULTS = {
      ema_1h_short: 21,
      ema_1h_long: 50,
      ema_15m: 34,
      min_1h_candles: 80,
      min_15m_candles: 120,
      tp_target: 0.006, # 60 bps
      sl_target: 0.004, # 40 bps
      maker_fee: 0.0005,
      slippage: 0.0002,
      risk_fraction: 0.005,
      # Futures-specific settings
      contract_size_usd: 100.0, # USD value per contract (e.g., $100 for BTC-USD-PERP)
      max_position_size: 10, # Maximum contracts to open
      min_position_size: 1 # Minimum contracts to open
    }.freeze

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    # Decide on a potential entry.
    # Returns:
    #   { side:, price:, quantity:, tp:, sl:, confidence: } or nil
    def signal(symbol:, equity_usd: 10_000.0)
      candles_1h = Candle.for_symbol(symbol).hourly.order(:timestamp).last(@config[:min_1h_candles])
      candles_15m = Candle.for_symbol(symbol).fifteen_minute.order(:timestamp).last(@config[:min_15m_candles])

      return nil if candles_1h.size < @config[:min_1h_candles]
      return nil if candles_15m.size < @config[:min_15m_candles]

      closes_1h = candles_1h.map { |c| c.close.to_f }
      ema1h_s = ema(closes_1h, @config[:ema_1h_short])
      ema1h_l = ema(closes_1h, @config[:ema_1h_long])
      trend = ema1h_s > ema1h_l ? :up : :down

      closes_15m = candles_15m.map { |c| c.close.to_f }
      ema15 = ema(closes_15m, @config[:ema_15m])
      last_15m = candles_15m.last

      # Trigger logic on 15m relative to its EMA
      # Long: last close above EMA with a recent EMA interaction and 1h uptrend
      # Short: last close below EMA with a recent EMA interaction and 1h downtrend
      recent = candles_15m.last(8)
      return nil if recent.size < 8

      last_close = last_15m.close.to_f

      # Track whether price interacted with EMA recently (pullback)
      interacted_with_ema = recent.any? do |c|
        (c.low.to_f <= ema15 && c.high.to_f >= ema15) || (c.close.to_f - ema15).abs / ema15 < 0.002
      end

      if trend == :up
        if interacted_with_ema && last_close > ema15
          entry = last_close
          be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:maker_fee], slippage_rate: @config[:slippage])
          tp = [ entry * (1.0 + @config[:tp_target]), be * 1.001 ].max
          sl = entry * (1.0 - @config[:sl_target])
          qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: @config[:risk_fraction])
          conf = confidence_score(trend: trend, ema1h_s: ema1h_s, ema1h_l: ema1h_l, ema15: ema15, last_price: last_close)
          return order_hash(:buy, entry, qty, tp, sl, conf)
        end
      else
        if interacted_with_ema && last_close < ema15
          entry = last_close
          be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:maker_fee], slippage_rate: @config[:slippage])
          tp = [ entry * (1.0 - @config[:tp_target]), be * 0.999 ].min
          sl = entry * (1.0 + @config[:sl_target])
          qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: @config[:risk_fraction])
          conf = confidence_score(trend: trend, ema1h_s: ema1h_s, ema1h_l: ema1h_l, ema15: ema15, last_price: last_close)
          return order_hash(:sell, entry, qty, tp, sl, conf)
        end
      end

      nil
    end

    private

    def ema(values, period)
      period = period.to_i
      return values.last.to_f if period <= 1 || values.empty?
      k = 2.0 / (period + 1)
      ema_value = values.first.to_f
      values.each do |v|
        ema_value = v.to_f * k + ema_value * (1 - k)
      end
      ema_value
    end

    def position_size(equity_usd:, entry:, sl:, risk_fraction:)
      risk_per_unit = (entry.to_f - sl.to_f).abs
      return 0 if risk_per_unit <= 0
      risk_budget = equity_usd.to_f * risk_fraction.to_f

      # Calculate BTC quantity based on risk
      btc_quantity = (risk_budget / risk_per_unit).floor(6)

      # Convert to futures contracts
      contract_quantity = (btc_quantity * entry.to_f / @config[:contract_size_usd]).round(0)

      # Apply position size limits
      contract_quantity = [ contract_quantity, @config[:max_position_size] ].min
      contract_quantity = [ contract_quantity, @config[:min_position_size] ].max

      contract_quantity
    end

    def order_hash(side, price, quantity, tp, sl, confidence)
      return nil if quantity.to_f <= 0
      {
        side: side,
        price: price,
        quantity: quantity,
        tp: tp,
        sl: sl,
        confidence: confidence
      }
    end

    def confidence_score(trend:, ema1h_s:, ema1h_l:, ema15:, last_price:)
      trend_strength = ((ema1h_s - ema1h_l).abs / [ ema1h_l.abs, 1e-9 ].max)
      alignment = (last_price - ema15).abs / [ ema15.abs, 1e-9 ].max
      score = (trend_strength.clamp(0, 0.02) / 0.02) * 0.7 + ((0.003 - alignment).clamp(0, 0.003) / 0.003) * 0.3
      (score * 100).round(1)
    end
  end
end
