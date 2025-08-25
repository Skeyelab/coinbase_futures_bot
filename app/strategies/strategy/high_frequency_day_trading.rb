# frozen_string_literal: true

class Strategy::HighFrequencyDayTrading
  attr_reader :ema_1m_fast, :ema_1m_slow, :ema_5m_trend, :min_1m_candles, :min_5m_candles

  def initialize(ema_1m_fast: 5, ema_1m_slow: 13, ema_5m_trend: 21, min_1m_candles: 20, min_5m_candles: 30)
    @ema_1m_fast = ema_1m_fast
    @ema_1m_slow = ema_1m_slow
    @ema_5m_trend = ema_5m_trend
    @min_1m_candles = min_1m_candles
    @min_5m_candles = min_5m_candles
  end

  def signal(symbol:, equity_usd:)
    # Get 1m and 5m candles for high-frequency analysis
    candles_1m = Candle.for_symbol(symbol).where(timeframe: '1m').order(:timestamp).last(@min_1m_candles + 10)
    candles_5m = Candle.for_symbol(symbol).where(timeframe: '5m').order(:timestamp).last(@min_5m_candles + 10)

    return nil if candles_1m.size < @min_1m_candles || candles_5m.size < @min_5m_candles

    # Calculate EMAs for different timeframes
    ema_1m_fast_values = calculate_ema(candles_1m.map(&:close), @ema_1m_fast)
    ema_1m_slow_values = calculate_ema(candles_1m.map(&:close), @ema_1m_slow)
    ema_5m_trend_values = calculate_ema(candles_5m.map(&:close), @ema_5m_trend)

    return nil if ema_1m_fast_values.size < 3 || ema_1m_slow_values.size < 3 || ema_5m_trend_values.size < 3

    # Get current values
    current_price = candles_1m.last.close
    current_1m_fast = ema_1m_fast_values.last
    current_1m_slow = ema_1m_slow_values.last
    prev_1m_fast = ema_1m_fast_values[-2]
    prev_1m_slow = ema_1m_slow_values[-2]
    
    # Get 5m trend direction
    current_5m_trend = ema_5m_trend_values.last
    prev_5m_trend = ema_5m_trend_values[-2]
    
    # 5m trend direction
    trend_direction = current_5m_trend > prev_5m_trend ? :up : :down
    price_above_5m_trend = current_price > current_5m_trend

    # 1m EMA crossover signals
    fast_above_slow = current_1m_fast > current_1m_slow
    prev_fast_above_slow = prev_1m_fast > prev_1m_slow
    bullish_crossover = fast_above_slow && !prev_fast_above_slow
    bearish_crossover = !fast_above_slow && prev_fast_above_slow

    # Volume and momentum checks
    volume_confirmation = check_volume_confirmation(candles_1m.last(5))
    momentum_strength = calculate_momentum_strength(candles_1m.last(10))

    # Generate signals based on confluence
    signal = nil
    confidence = 0

    # Long signal conditions
    if trend_direction == :up && price_above_5m_trend && bullish_crossover
      confidence = 70
      confidence += 10 if volume_confirmation
      confidence += 10 if momentum_strength > 0.6
      
      if confidence >= 75
        signal = generate_long_signal(symbol, current_price, equity_usd, confidence)
        signal[:signal_type] = confidence >= 85 ? 'immediate' : 'standard'
      end
    end

    # Short signal conditions (if trend allows)
    if trend_direction == :down && !price_above_5m_trend && bearish_crossover
      confidence = 70
      confidence += 10 if volume_confirmation
      confidence += 10 if momentum_strength > 0.6
      
      if confidence >= 75
        signal = generate_short_signal(symbol, current_price, equity_usd, confidence)
        signal[:signal_type] = confidence >= 85 ? 'immediate' : 'standard'
      end
    end

    # Quick pullback entries (lower confidence but faster)
    if !signal && trend_direction == :up && price_above_5m_trend
      pullback_signal = check_pullback_entry(candles_1m.last(5), current_1m_fast, :long)
      if pullback_signal
        signal = generate_long_signal(symbol, current_price, equity_usd, 65)
        signal[:signal_type] = 'pullback'
      end
    elsif !signal && trend_direction == :down && !price_above_5m_trend
      pullback_signal = check_pullback_entry(candles_1m.last(5), current_1m_fast, :short)
      if pullback_signal
        signal = generate_short_signal(symbol, current_price, equity_usd, 65)
        signal[:signal_type] = 'pullback'
      end
    end

    signal
  end

  private

  def calculate_ema(prices, period)
    return [] if prices.size < period

    alpha = 2.0 / (period + 1)
    ema_values = []
    
    # Simple moving average for first value
    ema_values << prices[0..period-1].sum / period.to_f
    
    # Calculate EMA for remaining values
    (period...prices.size).each do |i|
      ema = alpha * prices[i] + (1 - alpha) * ema_values.last
      ema_values << ema
    end
    
    ema_values
  end

  def check_volume_confirmation(recent_candles)
    return false if recent_candles.size < 3

    current_volume = recent_candles.last.volume
    avg_volume = recent_candles[0..-2].map(&:volume).sum / (recent_candles.size - 1).to_f

    # Volume confirmation if current volume is above average
    current_volume > avg_volume * 1.2
  end

  def calculate_momentum_strength(candles)
    return 0 if candles.size < 5

    price_changes = []
    candles.each_cons(2) do |prev_candle, curr_candle|
      price_changes << (curr_candle.close - prev_candle.close) / prev_candle.close
    end

    # Calculate momentum as consistency of price direction
    positive_moves = price_changes.count { |change| change > 0 }
    negative_moves = price_changes.count { |change| change < 0 }

    # Return strength based on consistency
    if positive_moves > negative_moves
      positive_moves.to_f / price_changes.size
    else
      negative_moves.to_f / price_changes.size
    end
  end

  def check_pullback_entry(recent_candles, ema_fast, direction)
    return false if recent_candles.size < 3

    current_price = recent_candles.last.close
    prev_price = recent_candles[-2].close

    # Check for price touching or approaching EMA
    if direction == :long
      # Price pulled back to or near EMA and now moving up
      current_price > ema_fast && prev_price <= ema_fast * 1.001
    else
      # Price pulled up to or near EMA and now moving down
      current_price < ema_fast && prev_price >= ema_fast * 0.999
    end
  end

  def generate_long_signal(symbol, current_price, equity_usd, confidence)
    # Day trading position sizing - smaller, more frequent trades
    risk_per_trade = 0.01  # 1% risk per trade for day trading
    stop_loss_pct = 0.005  # 0.5% stop loss for tight day trading
    take_profit_pct = 0.015 # 1.5% take profit (3:1 ratio)

    stop_loss_price = current_price * (1 - stop_loss_pct)
    take_profit_price = current_price * (1 + take_profit_pct)
    
    # Position size based on risk management
    risk_amount = equity_usd * risk_per_trade
    price_risk = current_price - stop_loss_price
    quantity = risk_amount / price_risk

    {
      side: 'buy',
      price: current_price,
      quantity: quantity.round(8),
      tp: take_profit_price,
      sl: stop_loss_price,
      confidence: confidence,
      timeframe: '1m_5m',
      strategy: 'high_frequency_day_trading'
    }
  end

  def generate_short_signal(symbol, current_price, equity_usd, confidence)
    # Day trading position sizing - smaller, more frequent trades
    risk_per_trade = 0.01  # 1% risk per trade for day trading
    stop_loss_pct = 0.005  # 0.5% stop loss for tight day trading
    take_profit_pct = 0.015 # 1.5% take profit (3:1 ratio)

    stop_loss_price = current_price * (1 + stop_loss_pct)
    take_profit_price = current_price * (1 - take_profit_pct)
    
    # Position size based on risk management
    risk_amount = equity_usd * risk_per_trade
    price_risk = stop_loss_price - current_price
    quantity = risk_amount / price_risk

    {
      side: 'sell',
      price: current_price,
      quantity: quantity.round(8),
      tp: take_profit_price,
      sl: stop_loss_price,
      confidence: confidence,
      timeframe: '1m_5m',
      strategy: 'high_frequency_day_trading'
    }
  end
end