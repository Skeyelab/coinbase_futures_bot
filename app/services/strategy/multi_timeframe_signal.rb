# frozen_string_literal: true

module Strategy
  # Multi-timeframe signal using 1h trend filter, 15m trend confirmation, 5m entry trigger, and 1m micro-timing.
  # - 1h: determine dominant trend via EMAs
  # - 15m: confirm intraday trend direction
  # - 5m: enter on pullback-and-reclaim (trend-following) or rejection (short)
  # - 1m: micro-entry timing and rapid position establishment
  # Returns order-like hash or nil when no setup.
  class MultiTimeframeSignal
    DEFAULTS = {
      ema_1h_short: 12,
      ema_1h_long: 26,
      ema_15m: 21,
      ema_5m: 13,
      ema_1m: 8,
      min_1h_candles: 80,
      min_15m_candles: 120,
      min_5m_candles: 100,
      min_1m_candles: 60,
      tp_target: 0.004, # 40 bps (tighter for day trading)
      sl_target: 0.003, # 30 bps (tighter for day trading)
      maker_fee: 0.0005,
      slippage: 0.0002,
      risk_fraction: 0.005,
      # Futures-specific settings
      contract_size_usd: 100.0, # USD value per contract (e.g., $100 for BTC-USD-PERP)
      max_position_size: 5, # Maximum contracts to open
      min_position_size: 1 # Minimum contracts to open
    }.freeze

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    # Decide on a potential entry.
    # Returns:
    #   { side:, price:, quantity:, tp:, sl:, confidence: } or nil
    def signal(symbol:, equity_usd: 10_000.0)
      # Support both perpetual and current month contracts
      # For current month contracts, use the symbol directly
      # For asset symbols (BTC, ETH), find the current month contract
      @current_symbol = resolve_trading_symbol(symbol)

      return nil unless @current_symbol

      candles_1h = Candle.for_symbol(@current_symbol).hourly.order(:timestamp).last(@config[:min_1h_candles])
      candles_15m = Candle.for_symbol(@current_symbol).fifteen_minute.order(:timestamp).last(@config[:min_15m_candles])
      candles_5m = Candle.for_symbol(@current_symbol).five_minute.order(:timestamp).last(@config[:min_5m_candles])
      candles_1m = Candle.for_symbol(@current_symbol).one_minute.order(:timestamp).last(@config[:min_1m_candles])

      return nil if candles_1h.size < @config[:min_1h_candles]
      return nil if candles_15m.size < @config[:min_15m_candles]
      return nil if candles_5m.size < @config[:min_5m_candles]
      return nil if candles_1m.size < @config[:min_1m_candles]

      # 1h trend analysis (dominant trend)
      closes_1h = candles_1h.map { |c| c.close.to_f }
      ema1h_s = ema(closes_1h, @config[:ema_1h_short])
      ema1h_l = ema(closes_1h, @config[:ema_1h_long])
      trend = ema1h_s > ema1h_l ? :up : :down

      # 15m trend confirmation (intraday direction)
      closes_15m = candles_15m.map { |c| c.close.to_f }
      ema15 = ema(closes_15m, @config[:ema_15m])
      last_15m = candles_15m.last

      # 5m entry trigger (short-term trend)
      closes_5m = candles_5m.map { |c| c.close.to_f }
      ema5 = ema(closes_5m, @config[:ema_5m])
      last_5m = candles_5m.last

      # 1m micro-timing (entry precision)
      closes_1m = candles_1m.map { |c| c.close.to_f }
      ema1 = ema(closes_1m, @config[:ema_1m])
      last_1m = candles_1m.last

      # Multi-timeframe confirmation logic
      return nil unless confirm_trend_alignment(trend, ema15, ema5, ema1, last_15m, last_5m, last_1m)

      # Entry logic on 5m relative to its EMA with 1m micro-timing
      recent_5m = candles_5m.last(8)
      recent_1m = candles_1m.last(5)
      return nil if recent_5m.size < 8 || recent_1m.size < 5

      last_close_5m = last_5m.close.to_f
      last_close_1m = last_1m.close.to_f

      # Track whether price interacted with 5m EMA recently (pullback)
      interacted_with_5m_ema = recent_5m.any? do |c|
        (c.low.to_f <= ema5 && c.high.to_f >= ema5) || (c.close.to_f - ema5).abs / ema5 < 0.002
      end

      # 1m micro-timing: ensure we're not too far from 1m EMA for precise entry
      micro_timing_ok = (last_close_1m - ema1).abs / ema1 < 0.0015

      if trend == :up
        if interacted_with_5m_ema && last_close_5m > ema5 && micro_timing_ok
          entry = last_close_1m # Use 1m close for precise entry
          be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:maker_fee], slippage_rate: @config[:slippage])
          tp = [ entry * (1.0 + @config[:tp_target]), be * 1.001 ].max
          sl = entry * (1.0 - @config[:sl_target])
          qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: @config[:risk_fraction])
          conf = confidence_score(trend: trend, ema1h_s: ema1h_s, ema1h_l: ema1h_l, ema15: ema15, ema5: ema5, ema1: ema1, last_price: last_close_1m)
          return order_hash(:buy, entry, qty, tp, sl, conf) if sentiment_gate_allows?(symbol: symbol, side: :buy)
        end
      else
        if interacted_with_5m_ema && last_close_5m < ema5 && micro_timing_ok
          entry = last_close_1m # Use 1m close for precise entry
          be = CostModel.break_even_exit(entry_price: entry, fee_rate: @config[:maker_fee], slippage_rate: @config[:slippage])
          tp = [ entry * (1.0 - @config[:tp_target]), be * 0.999 ].min
          sl = entry * (1.0 + @config[:sl_target])
          qty = position_size(equity_usd: equity_usd, entry: entry, sl: sl, risk_fraction: @config[:risk_fraction])
          conf = confidence_score(trend: trend, ema1h_s: ema1h_s, ema1h_l: ema1h_l, ema15: ema15, ema5: ema5, ema1: ema1, last_price: last_close_1m)
          return order_hash(:sell, entry, qty, tp, sl, conf) if sentiment_gate_allows?(symbol: symbol, side: :sell)
        end
      end

      nil
    end

    private

    def confirm_trend_alignment(trend, ema15, ema5, ema1, last_15m, last_5m, last_1m)
      # Ensure all timeframes are aligned with the dominant trend
      case trend
      when :up
        # Uptrend: ensure shorter timeframes are above their EMAs
        last_15m.close.to_f > ema15 && last_5m.close.to_f > ema5 && last_1m.close.to_f > ema1
      when :down
        # Downtrend: ensure shorter timeframes are below their EMAs
        last_15m.close.to_f < ema15 && last_5m.close.to_f < ema5 && last_1m.close.to_f < ema1
      else
        false
      end
    end

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

    def confidence_score(trend:, ema1h_s:, ema1h_l:, ema15:, ema5:, ema1:, last_price:)
      # 1. Trend strength (0-40 points)
      trend_strength = ((ema1h_s - ema1h_l).abs / [ ema1h_l.abs, 1e-9 ].max)
      trend_score = (trend_strength.clamp(0, 0.05) / 0.05) * 40

      # 2. Multi-timeframe alignment (0-25 points)
      # Check alignment across 15m, 5m, and 1m EMAs
      alignment_score = calculate_alignment_score(ema15, ema5, ema1, last_price)

      # 3. Volume confirmation (0-20 points)
      volume_score = volume_confidence_score

      # 4. Momentum confirmation (0-15 points)
      momentum_score = momentum_confidence_score

      total_score = trend_score + alignment_score + volume_score + momentum_score
      [ total_score, 100 ].min.round(1)
    end

    def calculate_alignment_score(ema15, ema5, ema1, last_price)
      # Calculate alignment scores for each timeframe
      alignment_15m = (last_price - ema15).abs / [ ema15.abs, 1e-9 ].max
      alignment_5m = (last_price - ema5).abs / [ ema5.abs, 1e-9 ].max
      alignment_1m = (last_price - ema1).abs / [ ema1.abs, 1e-9 ].max

      # Weight shorter timeframes more heavily for day trading
      score_15m = if alignment_15m < 0.001
        10 # Very close to 15m EMA
      elsif alignment_15m < 0.003
        8 # Good alignment
      elsif alignment_15m < 0.005
        6 # Moderate alignment
      else
        4 # Far from 15m EMA
      end

      score_5m = if alignment_5m < 0.001
        10 # Very close to 5m EMA
      elsif alignment_5m < 0.002
        8 # Good alignment
      elsif alignment_5m < 0.004
        6 # Moderate alignment
      else
        4 # Far from 5m EMA
      end

      score_1m = if alignment_1m < 0.0005
        5 # Very close to 1m EMA
      elsif alignment_1m < 0.001
        4 # Good alignment
      elsif alignment_1m < 0.002
        3 # Moderate alignment
      else
        2 # Far from 1m EMA
      end

      score_15m + score_5m + score_1m
    end

    def volume_confidence_score
      # Get recent 5m candles for volume analysis (better for day trading)
      recent_candles = Candle.for_symbol(@current_symbol).five_minute.order(:timestamp).last(10)
      return 0 if recent_candles.size < 10

      volumes = recent_candles.map { |c| c.volume.to_f }
      avg_volume = volumes.sum / volumes.size
      current_volume = volumes.last

      # Volume increasing trend
      recent_volumes = volumes.last(3)
      volume_trend = recent_volumes.last > recent_volumes.first ? 1.0 : 0.5

      # Current volume vs average
      volume_ratio = current_volume / [ avg_volume, 1e-9 ].max
      volume_ratio = [ volume_ratio, 3.0 ].min # Cap at 3x average

      # Score based on volume strength and trend
      (volume_ratio * volume_trend * 10).round(0)
    end

    def momentum_confidence_score
      # Get recent 5m closes for momentum analysis (better for day trading)
      recent_candles = Candle.for_symbol(@current_symbol).five_minute.order(:timestamp).last(8)
      return 0 if recent_candles.size < 8

      closes = recent_candles.map { |c| c.close.to_f }

      # Calculate rate of change over last 4 candles
      if closes.size >= 4
        roc_4 = (closes.last - closes[-4]) / closes[-4]
        roc_score = (roc_4.abs.clamp(0, 0.02) / 0.02) * 15
        roc_score.round(0)
      else
        0
      end
    end

    def latest_sentiment_z(symbol, window: "15m")
      rec = SentimentAggregate.where(symbol: symbol, window: window).order(window_end_at: :desc).first
      rec&.z_score&.to_f || 0.0
    end

    def sentiment_gate_allows?(symbol:, side:)
      enabled = ENV.fetch("SENTIMENT_ENABLE", "false").to_s.downcase == "true"
      return true unless enabled
      threshold = ENV.fetch("SENTIMENT_Z_THRESHOLD", "1.2").to_f
      z = latest_sentiment_z(symbol)
      return false if z.abs < threshold
      (side == :buy && z > 0) || (side == :sell && z < 0)
    end

    # Resolve the actual trading symbol to use
    # If given an asset symbol (BTC, ETH), find current month contract
    # If given a specific contract symbol, use it directly
    def resolve_trading_symbol(symbol)
      return nil unless symbol

      # If it's already a specific contract (contains date pattern), use it
      if symbol.match?(/\d{2}[A-Z]{3}\d{2}/)
        return symbol
      end

      # If it's an asset symbol (BTC, ETH), find current month contract
      asset = extract_asset_from_symbol(symbol)
      if asset
        contract_manager = MarketData::FuturesContractManager.new
        current_month_contract = contract_manager.current_month_contract(asset)

        if current_month_contract
          Rails.logger.info("[STRATEGY] Using current month contract #{current_month_contract} for asset #{asset}")
          return current_month_contract
        else
          Rails.logger.warn("[STRATEGY] No current month contract found for asset #{asset}")
          return nil
        end
      end

      # Default: return the symbol as-is
      symbol
    end

    # Extract asset symbol from various formats
    # Examples: BTC-USD -> BTC, ETH-USD -> ETH, BTC -> BTC
    def extract_asset_from_symbol(symbol)
      case symbol
      when /^(BTC|ETH)(-USD)?$/
        $1
      when /^(BIT|ET)-\d{2}[A-Z]{3}\d{2}-[A-Z]+$/
        # Current month contract: BIT-29AUG25-CDE -> BTC
        symbol.start_with?("BIT") ? "BTC" : "ETH"
      else
        nil
      end
    end
  end
end
