# frozen_string_literal: true

class MarketAnalysisService
  include SentryServiceTracking

  def initialize(symbol: nil, timeframe: "1h")
    @symbol = symbol || "BTC-USD"
    @timeframe = timeframe
    @analysis_time = Time.current.utc
  end

  def analyze_market
    track_service_call("analyze_market") do
      {
        symbol: @symbol,
        analysis_time: @analysis_time,
        price_data: analyze_price_data,
        technical_indicators: analyze_technical_indicators,
        sentiment_data: analyze_sentiment,
        position_data: analyze_positions,
        signal_data: analyze_signals,
        market_structure: analyze_market_structure,
        risk_assessment: assess_risk,
        trading_recommendation: generate_recommendation
      }
    end
  end

  def generate_advice
    analysis = analyze_market
    build_advice_text(analysis)
  end

  private

  def analyze_price_data
    recent_candles = get_recent_candles
    return {error: "No price data available"} if recent_candles.empty?

    latest = recent_candles.last
    price_change_1h = calculate_price_change(recent_candles, 1.hour)
    price_change_4h = calculate_price_change(recent_candles, 4.hours)
    price_change_24h = calculate_price_change(recent_candles, 24.hours)

    {
      current_price: latest.close.to_f,
      volume: latest.volume.to_f,
      price_change_1h: price_change_1h,
      price_change_4h: price_change_4h,
      price_change_24h: price_change_24h,
      high_24h: recent_candles.last(24).map(&:high).max.to_f,
      low_24h: recent_candles.last(24).map(&:low).min.to_f,
      volatility: calculate_volatility(recent_candles)
    }
  end

  def analyze_technical_indicators
    candles_1h = Candle.for_symbol(@symbol).hourly.order(:timestamp).last(50)
    candles_15m = Candle.for_symbol(@symbol).fifteen_minute.order(:timestamp).last(50)
    candles_5m = Candle.for_symbol(@symbol).five_minute.order(:timestamp).last(50)

    return {error: "Insufficient data for technical analysis"} if candles_1h.size < 20

    closes_1h = candles_1h.map { |c| c.close.to_f }
    closes_15m = candles_15m.map { |c| c.close.to_f }
    closes_5m = candles_5m.map { |c| c.close.to_f }

    {
      ema_12: calculate_ema(closes_1h, 12),
      ema_26: calculate_ema(closes_1h, 26),
      ema_50: calculate_ema(closes_1h, 50),
      rsi: calculate_rsi(closes_1h, 14),
      macd: calculate_macd(closes_1h),
      trend_direction: determine_trend_direction(closes_1h),
      support_resistance: find_support_resistance(candles_1h),
      momentum_15m: calculate_momentum(closes_15m),
      momentum_5m: calculate_momentum(closes_5m)
    }
  end

  def analyze_sentiment
    recent_sentiment = SentimentAggregate.for_symbol(@symbol)
      .where(window: "15m")
      .order(window_end_at: :desc)
      .first

    sentiment_events = SentimentEvent.for_symbol(@symbol)
      .recent(24.hours.ago)
      .where.not(score: nil)

    {
      current_sentiment: recent_sentiment&.z_score&.to_f || 0.0,
      sentiment_trend: calculate_sentiment_trend,
      news_volume: sentiment_events.count,
      average_sentiment: sentiment_events.average(:score)&.to_f || 0.0,
      sentiment_strength: classify_sentiment_strength(recent_sentiment&.z_score&.to_f || 0.0)
    }
  end

  def analyze_positions
    open_positions = Position.open.by_asset(extract_asset(@symbol))
    total_pnl = open_positions.sum { |p| p.pnl || 0 }
    day_positions = open_positions.day_trading.count
    swing_positions = open_positions.swing_trading.count

    {
      open_positions: open_positions.count,
      day_trading: day_positions,
      swing_trading: swing_positions,
      total_pnl: total_pnl,
      largest_position: largest_position(open_positions),
      position_risk: assess_position_risk(open_positions)
    }
  end

  def analyze_signals
    recent_signals = SignalAlert.for_symbol(@symbol).recent(24.hours)
    active_signals = recent_signals.active
    high_confidence = recent_signals.high_confidence(70)

    {
      active_signals: active_signals.count,
      recent_signals_24h: recent_signals.count,
      high_confidence_signals: high_confidence.count,
      last_signal_time: recent_signals.first&.alert_timestamp,
      signal_quality: assess_signal_quality(recent_signals),
      strategy_breakdown: breakdown_by_strategy(recent_signals)
    }
  end

  def analyze_market_structure
    candles_1h = Candle.for_symbol(@symbol).hourly.order(:timestamp).last(100)
    return {error: "Insufficient data for market structure analysis"} if candles_1h.size < 50

    {
      market_phase: determine_market_phase(candles_1h),
      trend_strength: calculate_trend_strength(candles_1h),
      consolidation_levels: find_consolidation_levels(candles_1h),
      breakout_potential: assess_breakout_potential(candles_1h),
      volume_profile: analyze_volume_profile(candles_1h)
    }
  end

  def assess_risk
    {
      market_risk: assess_market_risk,
      position_risk: assess_position_risk(Position.open.by_asset(extract_asset(@symbol))),
      volatility_risk: assess_volatility_risk,
      sentiment_risk: assess_sentiment_risk,
      overall_risk_level: calculate_overall_risk
    }
  end

  def generate_recommendation
    price_data = analyze_price_data
    return {action: "wait", confidence: 0, reason: "Insufficient data"} if price_data[:error]

    technical = analyze_technical_indicators
    sentiment = analyze_sentiment
    positions = analyze_positions
    signals = analyze_signals
    risk = assess_risk

    analysis = {
      price_data: price_data,
      technical_indicators: technical,
      sentiment_data: sentiment,
      position_data: positions,
      signal_data: signals,
      risk_assessment: risk
    }

    recommendation = build_recommendation(analysis)
    {
      action: recommendation[:action],
      confidence: recommendation[:confidence],
      reasoning: recommendation[:reasoning],
      entry_price: recommendation[:entry_price],
      stop_loss: recommendation[:stop_loss],
      take_profit: recommendation[:take_profit],
      position_size: recommendation[:position_size],
      timeframe: recommendation[:timeframe]
    }
  end

  def get_recent_candles
    case @timeframe
    when "1m"
      Candle.for_symbol(@symbol).one_minute.order(:timestamp).last(100)
    when "5m"
      Candle.for_symbol(@symbol).five_minute.order(:timestamp).last(100)
    when "15m"
      Candle.for_symbol(@symbol).fifteen_minute.order(:timestamp).last(100)
    when "1h"
      Candle.for_symbol(@symbol).hourly.order(:timestamp).last(100)
    else
      Candle.for_symbol(@symbol).hourly.order(:timestamp).last(100)
    end
  end

  def calculate_price_change(candles, period)
    return 0 if candles.empty?

    current_price = candles.last.close.to_f
    past_candle = candles.find { |c| c.timestamp <= (Time.current - period) }
    return 0 unless past_candle

    past_price = past_candle.close.to_f
    ((current_price - past_price) / past_price * 100).round(2)
  end

  def calculate_volatility(candles)
    return 0 if candles.size < 20

    returns = candles.last(20).each_cons(2).map do |prev, curr|
      (curr.close.to_f - prev.close.to_f) / prev.close.to_f
    end

    mean = returns.sum / returns.size
    variance = returns.map { |r| (r - mean)**2 }.sum / returns.size
    Math.sqrt(variance) * 100
  end

  def calculate_ema(prices, period)
    return 0 if prices.size < period

    multiplier = 2.0 / (period + 1)
    ema = prices.first(period).sum / period

    prices[period..].each do |price|
      ema = (price * multiplier) + (ema * (1 - multiplier))
    end

    ema.round(2)
  end

  def calculate_rsi(prices, period = 14)
    return 50 if prices.size < period + 1

    gains = []
    losses = []

    prices.each_cons(2) do |prev, curr|
      change = curr - prev
      if change > 0
        gains << change
        losses << 0
      else
        gains << 0
        losses << -change
      end
    end

    avg_gain = gains.last(period).sum / period.to_f
    avg_loss = losses.last(period).sum / period.to_f

    return 50 if avg_loss == 0

    rs = avg_gain / avg_loss
    rsi = 100 - (100 / (1 + rs))
    rsi.round(2)
  end

  def calculate_macd(prices)
    return {macd: 0, signal: 0, histogram: 0} if prices.size < 26

    ema_12 = calculate_ema(prices, 12)
    ema_26 = calculate_ema(prices, 26)
    macd_line = ema_12 - ema_26

    # Simplified signal line (9-period EMA of MACD)
    signal_line = calculate_ema([macd_line], 9)
    histogram = macd_line - signal_line

    {
      macd: macd_line.round(4),
      signal: signal_line.round(4),
      histogram: histogram.round(4)
    }
  end

  def determine_trend_direction(prices)
    return "neutral" if prices.size < 20

    ema_20 = calculate_ema(prices, 20)
    ema_50 = calculate_ema(prices, 50)
    current_price = prices.last

    if current_price > ema_20 && ema_20 > ema_50
      "strong_uptrend"
    elsif current_price > ema_20
      "uptrend"
    elsif current_price < ema_20 && ema_20 < ema_50
      "strong_downtrend"
    elsif current_price < ema_20
      "downtrend"
    else
      "sideways"
    end
  end

  def find_support_resistance(candles)
    return {support: 0, resistance: 0} if candles.empty?

    highs = candles.map(&:high).map(&:to_f)
    lows = candles.map(&:low).map(&:to_f)

    {
      support: lows.min,
      resistance: highs.max,
      current_level: candles.last.close.to_f
    }
  end

  def calculate_momentum(prices)
    return 0 if prices.size < 10

    recent_avg = prices.last(5).sum / 5.0
    older_avg = prices[-10..-6].sum / 5.0

    ((recent_avg - older_avg) / older_avg * 100).round(2)
  end

  def calculate_sentiment_trend
    recent_aggregates = SentimentAggregate.for_symbol(@symbol)
      .where(window: "15m")
      .order(window_end_at: :desc)
      .limit(4)

    return "neutral" if recent_aggregates.size < 2

    scores = recent_aggregates.map(&:z_score).compact
    return "neutral" if scores.size < 2

    if scores.first > scores.last + 0.5
      "improving"
    elsif scores.first < scores.last - 0.5
      "deteriorating"
    else
      "stable"
    end
  end

  def classify_sentiment_strength(z_score)
    case z_score.abs
    when 0..0.5
      "weak"
    when 0.5..1.0
      "moderate"
    when 1.0..2.0
      "strong"
    else
      "extreme"
    end
  end

  def largest_position(positions)
    return nil if positions.empty?

    largest = positions.max_by { |p| (p.size * p.entry_price).abs }
    {
      symbol: largest.product_id,
      side: largest.side,
      size: largest.size,
      value: (largest.size * largest.entry_price).abs.round(2)
    }
  end

  def assess_position_risk(positions)
    return "low" if positions.empty?

    total_exposure = positions.sum { |p| (p.size * p.entry_price).abs }
    return "low" if total_exposure < 1000

    case total_exposure
    when 0..5000
      "low"
    when 5000..15000
      "medium"
    else
      "high"
    end
  end

  def assess_signal_quality(signals)
    return "unknown" if signals.empty?

    avg_confidence = signals.average(:confidence) || 0
    recent_signals = signals.where("alert_timestamp >= ?", 6.hours.ago).count

    case avg_confidence
    when 0..50
      "poor"
    when 50..70
      (recent_signals > 2) ? "good" : "fair"
    when 70..85
      "good"
    else
      "excellent"
    end
  end

  def breakdown_by_strategy(signals)
    signals.group(:strategy_name).count
  end

  def determine_market_phase(candles)
    return "unknown" if candles.size < 50

    prices = candles.map { |c| c.close.to_f }
    volatility = calculate_volatility(candles)

    if volatility < 2.0
      "consolidation"
    elsif prices.last > prices.first * 1.05
      "uptrend"
    elsif prices.last < prices.first * 0.95
      "downtrend"
    else
      "sideways"
    end
  end

  def calculate_trend_strength(candles)
    return 0 if candles.size < 20

    prices = candles.map { |c| c.close.to_f }
    ema_20 = calculate_ema(prices, 20)
    current_price = prices.last

    ((current_price - ema_20) / ema_20 * 100).abs.round(2)
  end

  def find_consolidation_levels(candles)
    return [] if candles.size < 20

    prices = candles.map { |c| c.close.to_f }
    price_range = prices.max - prices.min
    current_price = prices.last

    levels = []
    (0..100).step(10) do |percent|
      level = prices.min + (price_range * percent / 100)
      if (current_price - level).abs < price_range * 0.05
        levels << level.round(2)
      end
    end

    levels
  end

  def assess_breakout_potential(candles)
    return "low" if candles.size < 20

    candles.map { |c| c.close.to_f }
    volatility = calculate_volatility(candles)
    volume_trend = analyze_volume_trend(candles)

    if volatility > 5.0 && volume_trend > 1.2
      "high"
    elsif volatility > 3.0 && volume_trend > 1.0
      "medium"
    else
      "low"
    end
  end

  def analyze_volume_profile(candles)
    return {trend: "unknown", average: 0} if candles.empty?

    volumes = candles.map { |c| c.volume.to_f }
    recent_avg = volumes.last(10).sum / 10.0
    older_avg = volumes.first(10).sum / 10.0

    {
      trend: (recent_avg > older_avg * 1.2) ? "increasing" : "decreasing",
      average: volumes.sum / volumes.size,
      recent: recent_avg
    }
  end

  def analyze_volume_trend(candles)
    return 1.0 if candles.size < 10

    recent_volumes = candles.last(5).map { |c| c.volume.to_f }
    older_volumes = candles[-10..-6].map { |c| c.volume.to_f }

    recent_avg = recent_volumes.sum / recent_volumes.size
    older_avg = older_volumes.sum / older_volumes.size

    (older_avg > 0) ? recent_avg / older_avg : 1.0
  end

  def assess_market_risk
    candles = get_recent_candles
    return "unknown" if candles.empty?

    volatility = calculate_volatility(candles)
    price_change_24h = calculate_price_change(candles, 24.hours)

    if volatility > 8.0 || price_change_24h.abs > 15
      "high"
    elsif volatility > 5.0 || price_change_24h.abs > 8
      "medium"
    else
      "low"
    end
  end

  def assess_volatility_risk
    candles = get_recent_candles
    return "unknown" if candles.empty?

    volatility = calculate_volatility(candles)

    case volatility
    when 0..3
      "low"
    when 3..6
      "medium"
    else
      "high"
    end
  end

  def assess_sentiment_risk
    sentiment = SentimentAggregate.for_symbol(@symbol)
      .where(window: "15m")
      .order(window_end_at: :desc)
      .first

    z_score = sentiment&.z_score&.to_f || 0

    case z_score.abs
    when 0..1.0
      "low"
    when 1.0..2.0
      "medium"
    else
      "high"
    end
  end

  def calculate_overall_risk
    market_risk = assess_market_risk
    position_risk = assess_position_risk(Position.open.by_asset(extract_asset(@symbol)))
    volatility_risk = assess_volatility_risk
    sentiment_risk = assess_sentiment_risk

    risks = [market_risk, position_risk, volatility_risk, sentiment_risk]
    high_count = risks.count("high")
    medium_count = risks.count("medium")

    if high_count >= 2
      "high"
    elsif high_count == 1 || medium_count >= 2
      "medium"
    else
      "low"
    end
  end

  def build_recommendation(analysis)
    price_data = analysis[:price_data]
    technical = analysis[:technical_indicators]
    sentiment = analysis[:sentiment_data]
    analysis[:position_data]
    signals = analysis[:signal_data]
    risk = analysis[:risk_assessment]

    # Decision logic based on multiple factors
    recommendation = analyze_trading_opportunity(price_data, technical, sentiment, signals, risk)

    {
      action: recommendation[:action],
      confidence: recommendation[:confidence],
      reasoning: recommendation[:reasoning],
      entry_price: recommendation[:entry_price],
      stop_loss: recommendation[:stop_loss],
      take_profit: recommendation[:take_profit],
      position_size: recommendation[:position_size],
      timeframe: recommendation[:timeframe]
    }
  end

  def analyze_trading_opportunity(price_data, technical, sentiment, signals, risk)
    return {action: "wait", confidence: 0, reasoning: "Insufficient data"} if price_data[:error]

    # Scoring system for different factors
    trend_score = score_trend(technical[:trend_direction])
    momentum_score = score_momentum(technical[:momentum_15m], technical[:momentum_5m])
    sentiment_score = score_sentiment(sentiment[:current_sentiment])
    signal_score = score_signals(signals[:signal_quality])
    risk_score = score_risk(risk[:overall_risk_level])

    total_score = trend_score + momentum_score + sentiment_score + signal_score - risk_score

    # Generate recommendation based on total score
    if total_score >= 7
      generate_long_recommendation(price_data, technical, risk)
    elsif total_score <= -7
      generate_short_recommendation(price_data, technical, risk)
    else
      generate_wait_recommendation(total_score, risk)
    end
  end

  def score_trend(trend_direction)
    case trend_direction
    when "strong_uptrend"
      3
    when "uptrend"
      2
    when "strong_downtrend"
      -3
    when "downtrend"
      -2
    else
      0
    end
  end

  def score_momentum(momentum_15m, momentum_5m)
    score = 0
    score += if momentum_15m > 2
      2
    else
      (momentum_15m < -2) ? -2 : 0
    end
    score += if momentum_5m > 1
      1
    else
      (momentum_5m < -1) ? -1 : 0
    end
    score
  end

  def score_sentiment(sentiment_z)
    case sentiment_z
    when 1.5..Float::INFINITY
      2
    when 0.5..1.5
      1
    when -1.5..-0.5
      -1
    when -Float::INFINITY..-1.5
      -2
    else
      0
    end
  end

  def score_signals(signal_quality)
    case signal_quality
    when "excellent"
      2
    when "good"
      1
    when "fair"
      0
    else
      -1
    end
  end

  def score_risk(risk_level)
    case risk_level
    when "high"
      3
    when "medium"
      1
    else
      0
    end
  end

  def generate_long_recommendation(price_data, technical, risk)
    current_price = price_data[:current_price]
    stop_loss = current_price * 0.98  # 2% stop loss
    take_profit = current_price * 1.04  # 4% take profit
    position_size = calculate_position_size(current_price, stop_loss, risk[:overall_risk_level])

    {
      action: "long",
      confidence: 75,
      reasoning: "Strong bullish signals across multiple timeframes with positive momentum and sentiment",
      entry_price: current_price,
      stop_loss: stop_loss.round(2),
      take_profit: take_profit.round(2),
      position_size: position_size,
      timeframe: "1-4 hours"
    }
  end

  def generate_short_recommendation(price_data, technical, risk)
    current_price = price_data[:current_price]
    stop_loss = current_price * 1.02  # 2% stop loss
    take_profit = current_price * 0.96  # 4% take profit
    position_size = calculate_position_size(current_price, stop_loss, risk[:overall_risk_level])

    {
      action: "short",
      confidence: 75,
      reasoning: "Strong bearish signals across multiple timeframes with negative momentum and sentiment",
      entry_price: current_price,
      stop_loss: stop_loss.round(2),
      take_profit: take_profit.round(2),
      position_size: position_size,
      timeframe: "1-4 hours"
    }
  end

  def generate_wait_recommendation(total_score, risk)
    {
      action: "wait",
      confidence: 60,
      reasoning: "Mixed signals - waiting for clearer direction. Risk level: #{risk[:overall_risk_level]}",
      entry_price: nil,
      stop_loss: nil,
      take_profit: nil,
      position_size: 0,
      timeframe: "monitor for 1-2 hours"
    }
  end

  def calculate_position_size(entry_price, stop_loss, risk_level)
    base_equity = ENV.fetch("SIGNAL_EQUITY_USD", "10000").to_f
    risk_per_trade = case risk_level
    when "low"
      0.02
    when "medium"
      0.015
    else
      0.01
    end

    risk_amount = base_equity * risk_per_trade
    price_risk = (entry_price - stop_loss).abs
    (risk_amount / price_risk).round(2)
  end

  def extract_asset(symbol)
    symbol.split("-").first
  end

  def build_advice_text(analysis)
    return "❌ Unable to analyze market - insufficient data" if analysis[:price_data][:error]

    advice = "📊 **Market Analysis for #{analysis[:symbol]}**\n\n"

    # Price summary
    price = analysis[:price_data]
    advice += "💰 **Current Price**: $#{price[:current_price]}\n"
    advice += "📈 **24h Change**: #{price[:price_change_24h]}%\n"
    advice += "📊 **Volatility**: #{price[:volatility]}%\n\n"

    # Technical analysis
    tech = analysis[:technical_indicators]
    advice += "🔧 **Technical Analysis**\n"
    advice += "• Trend: #{tech[:trend_direction].humanize}\n"
    advice += "• RSI: #{tech[:rsi]} (#{rsi_interpretation(tech[:rsi])})\n"
    advice += "• MACD: #{tech[:macd][:macd]} (Signal: #{tech[:macd][:signal]})\n\n"

    # Sentiment
    sentiment = analysis[:sentiment_data]
    advice += "😊 **Sentiment Analysis**\n"
    advice += "• Current: #{sentiment[:sentiment_strength]} (#{sentiment[:current_sentiment].round(2)})\n"
    advice += "• Trend: #{sentiment[:sentiment_trend]}\n"
    advice += "• News Volume: #{sentiment[:news_volume]} articles\n\n"

    # Positions
    positions = analysis[:position_data]
    advice += "📋 **Current Positions**\n"
    advice += "• Open: #{positions[:open_positions]} (#{positions[:day_trading]} day, #{positions[:swing_trading]} swing)\n"
    advice += "• Total PnL: $#{positions[:total_pnl].round(2)}\n\n"

    # Risk assessment
    risk = analysis[:risk_assessment]
    advice += "⚠️ **Risk Assessment**\n"
    advice += "• Overall Risk: #{risk[:overall_risk_level].upcase}\n"
    advice += "• Market Risk: #{risk[:market_risk].upcase}\n"
    advice += "• Volatility Risk: #{risk[:volatility_risk].upcase}\n\n"

    # Recommendation
    rec = analysis[:trading_recommendation]
    advice += "🎯 **Trading Recommendation**\n"
    advice += "• Action: **#{rec[:action].upcase}**\n"
    advice += "• Confidence: #{rec[:confidence]}%\n"
    advice += "• Reasoning: #{rec[:reasoning]}\n"

    if rec[:entry_price]
      advice += "• Entry: $#{rec[:entry_price]}\n"
      advice += "• Stop Loss: $#{rec[:stop_loss]}\n"
      advice += "• Take Profit: $#{rec[:take_profit]}\n"
      advice += "• Position Size: #{rec[:position_size]} contracts\n"
    end

    advice += "• Timeframe: #{rec[:timeframe]}\n"

    advice
  end

  def rsi_interpretation(rsi)
    case rsi
    when 0..30
      "Oversold"
    when 30..50
      "Bearish"
    when 50..70
      "Bullish"
    when 70..100
      "Overbought"
    else
      "Unknown"
    end
  end
end
