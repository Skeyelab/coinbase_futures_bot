# frozen_string_literal: true

module Strategy
  class Pullback1h
    DEFAULTS = {
      maker_fee: 0.0005,
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
    end

    # Given recent candles, return a potential order: { side:, price:, quantity:, tp:, sl: }
    def signal(candles:, symbol:, equity_usd: 1000.0)
      return nil if candles.size < @config[:min_candles]

      closes = candles.map { |c| c.close.to_f }
      ema_short = ema(closes, @config[:ema_short])
      ema_long = ema(closes, @config[:ema_long])
      last = candles.last

      # Trend analysis
      uptrend = last.close.to_f > ema_long
      pullback = last.low.to_f <= ema_short && last.close.to_f >= ema_short

      # Additional confirmation: volume and momentum
      volume_confirmation = volume_increasing?(candles)
      momentum_confirmation = momentum_positive?(closes)

      return nil unless uptrend && pullback && volume_confirmation && momentum_confirmation

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
        sl: sl,
        confidence: calculate_confidence(candles, ema_short, ema_long)
      }
    end

    # Backtest the strategy over available data
    def backtest(candles:, symbol:, equity_usd: 1000.0)
      return nil if candles.size < @config[:min_candles]

      results = []
      current_equity = equity_usd

      # Test strategy on each candle after minimum required
      (@config[:min_candles]..candles.size-1).each do |i|
        test_candles = candles[0..i]
        signal = signal(candles: test_candles, symbol: symbol, equity_usd: current_equity)

        if signal
          # Simulate trade execution
          trade_result = simulate_trade(signal, test_candles.last, current_equity)
          results << trade_result
          current_equity = trade_result[:final_equity]
        end
      end

      {
        total_trades: results.size,
        winning_trades: results.count { |r| r[:pnl] > 0 },
        total_pnl: results.sum { |r| r[:pnl] },
        final_equity: current_equity,
        trades: results
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
      [ confidence, 100 ].min.round(1)
    end

    def simulate_trade(signal, entry_candle, equity)
      # Simple trade simulation - in reality you'd track the trade through multiple candles
      entry_price = signal[:price]
      quantity = signal[:quantity]

      # For backtesting, assume we hit take profit or stop loss
      # This is simplified - real backtesting would track each candle
      if rand > 0.5  # 50% win rate for demo
        exit_price = signal[:tp]
        pnl = CostModel.round_trip_net_pnl(
          entry_price: entry_price,
          exit_price: exit_price,
          quantity: quantity,
          fee_rate: @config[:maker_fee],
          slippage_rate: @config[:slippage]
        )
      else
        exit_price = signal[:sl]
        pnl = CostModel.round_trip_net_pnl(
          entry_price: entry_price,
          exit_price: exit_price,
          quantity: quantity,
          fee_rate: @config[:maker_fee],
          slippage_rate: @config[:slippage]
        )
      end

      {
        entry_price: entry_price,
        exit_price: exit_price,
        quantity: quantity,
        pnl: pnl,
        final_equity: equity + pnl,
        timestamp: entry_candle.timestamp
      }
    end
  end
end
