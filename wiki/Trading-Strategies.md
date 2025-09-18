# Trading Strategies

## Overview

The coinbase_futures_bot implements sophisticated **multi-timeframe trading strategies** optimized for **day trading** operations. The system combines technical analysis, sentiment analysis, and risk management to generate high-confidence trading signals with rapid entry/exit cycles.

## Strategy Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Multi-Timeframe Analysis                     │
├─────────────────────────────────────────────────────────────────┤
│  1h Timeframe (Trend)    │  15m Timeframe (Confirmation)       │
│  • Long-term trend       │  • Intraday direction               │
│  • EMA 21 vs EMA 50      │  • EMA 21 confirmation              │
│  • Market regime         │  • Trend strength                   │
│                          │                                     │
│  5m Timeframe (Entry)    │  1m Timeframe (Precision)           │
│  • Entry triggers        │  • Micro-timing                     │
│  • EMA 13 pullbacks      │  • EMA 8 reclaims                   │
│  • Short-term momentum   │  • Precise entry points             │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Signal Filtering                          │
├─────────────────────────────────────────────────────────────────┤
│  Sentiment Analysis      │  Risk Management                    │
│  • News sentiment        │  • Position sizing                  │
│  • Z-score filtering     │  • Stop loss (30-40 bps)           │
│  • Confidence gating     │  • Take profit (40-60 bps)         │
│  • Market context        │  • Day trading limits              │
└─────────────────────────────────────────────────────────────────┘
```

## Core Strategy: Multi-Timeframe Signal

### Strategy Overview

The **MultiTimeframeSignal** strategy is the primary trading algorithm, designed for intraday futures trading with the following characteristics:

- **Position Duration**: 1-8 hours (same-day closure)
- **Entry Precision**: 1-minute and 5-minute timeframe analysis
- **Risk Management**: Tight stops (20-40 bps) and quick profits (40-60 bps)
- **Success Rate Target**: 60-70% with 1:1.5 risk/reward ratio

### Timeframe Hierarchy

#### 1. 1-Hour Trend Analysis (Dominant Direction)

**Purpose**: Determines the overall market trend and trading bias.

**Indicators**:
- **EMA 21** (short-term trend)
- **EMA 50** (medium-term trend)
- **Trend Direction**: EMA 21 > EMA 50 = Bullish, EMA 21 < EMA 50 = Bearish

**Logic**:
```ruby
# 1h trend determination
closes_1h = candles_1h.map { |c| c.close.to_f }
ema1h_short = ema(closes_1h, 21)  # 21-period EMA
ema1h_long = ema(closes_1h, 50)   # 50-period EMA

trend = (ema1h_short > ema1h_long) ? :up : :down
```

**Trade Bias**:
- **Bullish Trend**: Only long positions allowed
- **Bearish Trend**: Only short positions allowed
- **Trend Strength**: Measured by EMA separation

#### 2. 15-Minute Confirmation (Intraday Direction)

**Purpose**: Confirms the 1-hour trend on an intraday basis and filters false signals.

**Indicators**:
- **EMA 21** for intraday trend
- **Price Action**: Current price relative to EMA

**Confirmation Rules**:
- **Long Signals**: 15m price > 15m EMA AND 1h trend is bullish
- **Short Signals**: 15m price < 15m EMA AND 1h trend is bearish
- **Strength Filter**: EMA slope and price distance from EMA

#### 3. 5-Minute Entry Triggers (Short-term Momentum)

**Purpose**: Identifies specific entry opportunities with pullback logic.

**Indicators**:
- **EMA 13** for short-term trend
- **Pullback Detection**: Price temporarily moves against trend
- **Momentum Confirmation**: Price reclaims EMA after pullback

**Entry Logic**:
```ruby
# 5m entry conditions
closes_5m = candles_5m.map { |c| c.close.to_f }
ema5 = ema(closes_5m, 13)
last_5m = candles_5m.last

# Long entry: price reclaims 5m EMA after pullback
long_entry = (last_5m.close > ema5) && (trend == :up)

# Short entry: price breaks below 5m EMA after rally
short_entry = (last_5m.close < ema5) && (trend == :down)
```

#### 4. 1-Minute Precision Timing (Micro-entries)

**Purpose**: Fine-tunes entry timing for optimal fills and reduced slippage.

**Indicators**:
- **EMA 8** for micro-trend
- **Entry Confirmation**: Price action relative to 1m EMA
- **Volume Confirmation**: Trading volume validation

**Precision Entry**:
- **Long**: 1m price crosses above 1m EMA with volume
- **Short**: 1m price crosses below 1m EMA with volume
- **Stop Placement**: Based on recent swing low/high on 1m chart

### Signal Generation Process

#### Step 1: Data Validation

```ruby
def signal(symbol:, equity_usd: 10_000.0)
  # Ensure sufficient data for analysis
  return nil if candles_1h.size < min_1h_candles
  return nil if candles_15m.size < min_15m_candles
  return nil if candles_5m.size < min_5m_candles
  return nil if candles_1m.size < min_1m_candles
  
  # Continue with analysis...
end
```

#### Step 2: Multi-Timeframe Analysis

```ruby
# 1h trend analysis
trend = determine_1h_trend(candles_1h)
return nil unless trend_is_strong?(trend)

# 15m confirmation
return nil unless confirm_15m_trend(candles_15m, trend)

# 5m entry trigger
entry_signal = detect_5m_entry(candles_5m, trend)
return nil unless entry_signal

# 1m precision timing
return nil unless confirm_1m_timing(candles_1m, trend)
```

#### Step 3: Sentiment Filtering

```ruby
# Apply sentiment z-score filter
sentiment_z = get_sentiment_z_score(symbol, "15m")
sentiment_threshold = ENV.fetch("SENTIMENT_Z_THRESHOLD", "1.2").to_f

# Filter signals based on sentiment
if sentiment_z.abs < sentiment_threshold
  return nil  # Neutral sentiment - skip signal
end

# Sentiment alignment check
sentiment_bullish = sentiment_z > 0
return nil if trend == :up && !sentiment_bullish
return nil if trend == :down && sentiment_bullish
```

#### Step 4: Position Sizing and Risk Management

```ruby
# Calculate position size based on risk
current_price = candles_5m.last.close.to_f
stop_distance = calculate_stop_distance(current_price, trend)
risk_per_share = stop_distance

# Position sizing (1-2% risk per trade)
risk_amount = equity_usd * 0.015  # 1.5% risk
position_size = (risk_amount / risk_per_share).floor

# Apply position limits
position_size = [position_size, max_position_size].min
position_size = [position_size, min_position_size].max
```

#### Step 5: Signal Construction

```ruby
{
  side: trend == :up ? "long" : "short",
  price: current_price,
  quantity: position_size,
  stop_loss: calculate_stop_loss(current_price, trend),
  take_profit: calculate_take_profit(current_price, trend),
  confidence: calculate_confidence(trend_strength, sentiment_z),
  timeframe: "5m",
  strategy: "multi_timeframe_signal",
  metadata: {
    trend_1h: trend,
    ema_alignment: ema_alignment_score,
    sentiment_z: sentiment_z,
    volatility: recent_volatility
  }
}
```

## Strategy Configuration

### Default Parameters

```ruby
{
  ema_1h_short: 21,        # 1h short EMA period
  ema_1h_long: 50,         # 1h long EMA period
  ema_15m: 21,             # 15m EMA period
  ema_5m: 13,              # 5m EMA period
  ema_1m: 8,               # 1m EMA period
  
  min_1h_candles: 60,      # Minimum 1h candles required
  min_15m_candles: 80,     # Minimum 15m candles required
  min_5m_candles: 60,      # Minimum 5m candles required
  min_1m_candles: 30,      # Minimum 1m candles required
  
  tp_target: 0.004,        # Take profit target (40 bps)
  sl_target: 0.003,        # Stop loss target (30 bps)
  
  max_position_size: 10,   # Maximum contracts per position
  min_position_size: 1,    # Minimum contracts per position
  
  confidence_threshold: 70 # Minimum confidence for signal
}
```

### Day Trading Optimizations

```ruby
# Day trading specific parameters
day_trading_config = {
  tp_target: 0.004,        # Tighter take profits (40 bps)
  sl_target: 0.003,        # Tighter stop losses (30 bps)
  max_hold_hours: 6,       # Maximum position duration
  force_close_time: "15:30", # Force close before market close
  
  # More aggressive entry criteria
  confidence_threshold: 75,  # Higher confidence required
  sentiment_threshold: 1.0,  # Lower sentiment threshold
  
  # Faster timeframe emphasis
  ema_5m: 8,               # Faster 5m EMA
  ema_1m: 5                # Faster 1m EMA
}
```

## Supporting Strategies

### 1. Spot-Driven Strategy

**Purpose**: Generates futures signals based on spot market analysis.

**Key Features**:
- Analyzes spot market trends (BTC-USD, ETH-USD)
- Maps spot signals to corresponding futures contracts
- Cross-market arbitrage opportunities
- Basis risk management

**Usage**:
```ruby
strategy = Strategy::SpotDrivenStrategy.new
signals = strategy.generate_signals(
  product_ids: ["BTC-USD", "ETH-USD"],
  as_of: Time.current
)
```

### 2. Pullback Strategy

**Purpose**: Specialized pullback entry strategy for trend-following trades.

**Key Features**:
- 1-hour timeframe pullback detection
- Fibonacci retracement levels
- Support/resistance confirmation
- Volume-based entry validation

**Entry Conditions**:
- Strong 1h trend established
- Price pulls back to EMA or key level
- Volume decreases during pullback
- Volume increases on trend resumption

## Risk Management Framework

### Position Sizing Rules

#### Kelly Criterion Application
```ruby
def calculate_kelly_position_size(win_rate, avg_win, avg_loss, equity)
  # Kelly formula: f = (bp - q) / b
  # where: b = avg_win/avg_loss, p = win_rate, q = 1 - win_rate
  
  b = avg_win / avg_loss
  p = win_rate
  q = 1 - win_rate
  
  kelly_fraction = (b * p - q) / b
  
  # Use 25% of Kelly for conservative sizing
  conservative_kelly = kelly_fraction * 0.25
  
  position_size = equity * conservative_kelly
  position_size.clamp(equity * 0.01, equity * 0.05)  # 1-5% max
end
```

#### Volatility-Based Sizing
```ruby
def volatility_based_sizing(current_price, volatility, equity)
  # Adjust position size based on recent volatility
  base_risk = equity * 0.015  # 1.5% base risk
  
  # Volatility adjustment (higher vol = smaller size)
  vol_adjustment = 1.0 / (1.0 + volatility * 10)
  
  adjusted_risk = base_risk * vol_adjustment
  stop_distance = current_price * sl_target
  
  position_size = (adjusted_risk / stop_distance).floor
end
```

### Stop Loss Management

#### Dynamic Stop Losses
```ruby
def calculate_dynamic_stop_loss(entry_price, side, volatility)
  base_stop_pct = sl_target  # 0.003 (30 bps)
  
  # Adjust for volatility
  vol_adjustment = 1.0 + (volatility - 0.02) * 5  # Scale around 2% vol
  adjusted_stop_pct = base_stop_pct * vol_adjustment
  
  # Ensure reasonable bounds
  adjusted_stop_pct = adjusted_stop_pct.clamp(0.002, 0.006)  # 20-60 bps
  
  if side == "long"
    entry_price * (1 - adjusted_stop_pct)
  else
    entry_price * (1 + adjusted_stop_pct)
  end
end
```

#### Trailing Stops
```ruby
def update_trailing_stop(position, current_price)
  return unless position.open?
  
  if position.side == "LONG"
    # Trail stop up for long positions
    new_stop = current_price * (1 - sl_target)
    position.update!(stop_loss: new_stop) if new_stop > position.stop_loss
  else
    # Trail stop down for short positions
    new_stop = current_price * (1 + sl_target)
    position.update!(stop_loss: new_stop) if new_stop < position.stop_loss
  end
end
```

### Take Profit Management

#### Scaled Exit Strategy
```ruby
def calculate_scaled_exits(entry_price, side, position_size)
  exits = []
  
  if side == "long"
    # Scale out at multiple levels
    exits << {
      price: entry_price * 1.002,  # 20 bps - quick profit
      quantity: (position_size * 0.3).floor,
      reason: "quick_profit"
    }
    exits << {
      price: entry_price * 1.004,  # 40 bps - main target
      quantity: (position_size * 0.5).floor,
      reason: "main_target"
    }
    exits << {
      price: entry_price * 1.006,  # 60 bps - extended target
      quantity: (position_size * 0.2).floor,
      reason: "extended_target"
    }
  else
    # Mirror for short positions
    exits << {
      price: entry_price * 0.998,
      quantity: (position_size * 0.3).floor,
      reason: "quick_profit"
    }
    # ... similar structure for short
  end
  
  exits
end
```

## Performance Optimization

### Signal Quality Metrics

#### Confidence Scoring
```ruby
def calculate_confidence(trend_strength, sentiment_z, volatility)
  base_confidence = 50
  
  # Trend strength component (0-30 points)
  trend_score = (trend_strength * 30).clamp(0, 30)
  
  # Sentiment component (0-20 points)
  sentiment_score = (sentiment_z.abs * 10).clamp(0, 20)
  
  # Volatility component (-10 to +10 points)
  vol_score = ((0.03 - volatility) * 500).clamp(-10, 10)
  
  total_confidence = base_confidence + trend_score + sentiment_score + vol_score
  total_confidence.clamp(0, 100)
end
```

#### Signal Filtering
```ruby
def should_generate_signal?(confidence, sentiment_z, recent_signals)
  # Minimum confidence threshold
  return false if confidence < confidence_threshold
  
  # Sentiment alignment
  return false if sentiment_z.abs < sentiment_threshold
  
  # Avoid over-trading
  return false if recent_signals.count > 3
  
  # Market hours filter (for day trading)
  return false unless market_hours?
  
  true
end
```

### Backtesting Framework

#### Historical Performance Analysis
```ruby
def backtest_strategy(start_date, end_date, initial_equity)
  results = {
    trades: [],
    equity_curve: [],
    metrics: {}
  }
  
  # Replay historical data
  Tick.where(observed_at: start_date..end_date).find_each do |tick|
    # Update candles with tick data
    update_candles_with_tick(tick)
    
    # Generate signals
    signal = strategy.signal(symbol: tick.product_id, equity_usd: current_equity)
    
    if signal
      # Simulate trade execution
      trade_result = simulate_trade(signal, tick.price)
      results[:trades] << trade_result
      
      # Update equity
      current_equity += trade_result[:pnl]
      results[:equity_curve] << {
        timestamp: tick.observed_at,
        equity: current_equity
      }
    end
  end
  
  # Calculate performance metrics
  results[:metrics] = calculate_performance_metrics(results[:trades])
  results
end
```

#### Performance Metrics
```ruby
def calculate_performance_metrics(trades)
  winning_trades = trades.select { |t| t[:pnl] > 0 }
  losing_trades = trades.select { |t| t[:pnl] <= 0 }
  
  {
    total_trades: trades.count,
    win_rate: winning_trades.count.to_f / trades.count,
    avg_win: winning_trades.sum { |t| t[:pnl] } / winning_trades.count,
    avg_loss: losing_trades.sum { |t| t[:pnl] } / losing_trades.count,
    profit_factor: winning_trades.sum { |t| t[:pnl] }.abs / losing_trades.sum { |t| t[:pnl] }.abs,
    max_drawdown: calculate_max_drawdown(trades),
    sharpe_ratio: calculate_sharpe_ratio(trades),
    total_pnl: trades.sum { |t| t[:pnl] }
  }
end
```

## Strategy Monitoring

### Real-time Performance Tracking
```ruby
class StrategyMonitor
  def track_signal_performance(signal, execution_result)
    # Record signal generation
    signal_record = SignalPerformance.create!(
      strategy_name: signal[:strategy],
      symbol: signal[:symbol],
      confidence: signal[:confidence],
      generated_at: Time.current,
      expected_profit: signal[:take_profit] - signal[:price]
    )
    
    # Track execution
    if execution_result[:success]
      signal_record.update!(
        executed_at: Time.current,
        execution_price: execution_result[:fill_price],
        execution_slippage: execution_result[:slippage]
      )
    end
  end
  
  def calculate_strategy_metrics(strategy_name, period = 30.days)
    signals = SignalPerformance.where(
      strategy_name: strategy_name,
      generated_at: period.ago..Time.current
    )
    
    {
      total_signals: signals.count,
      execution_rate: signals.where.not(executed_at: nil).count.to_f / signals.count,
      avg_confidence: signals.average(:confidence),
      avg_slippage: signals.average(:execution_slippage)
    }
  end
end
```

### Adaptive Parameter Tuning
```ruby
class StrategyOptimizer
  def optimize_parameters(strategy_class, historical_data, parameter_ranges)
    best_params = nil
    best_performance = -Float::INFINITY
    
    # Grid search over parameter space
    parameter_combinations(parameter_ranges).each do |params|
      strategy = strategy_class.new(params)
      
      # Backtest with these parameters
      results = backtest_strategy(strategy, historical_data)
      
      # Evaluate performance (e.g., Sharpe ratio)
      performance_score = results[:metrics][:sharpe_ratio]
      
      if performance_score > best_performance
        best_performance = performance_score
        best_params = params
      end
    end
    
    best_params
  end
end
```

## Integration with System

### Job-based Signal Generation
```ruby
# In GenerateSignalsJob
def perform(equity_usd: default_equity_usd)
  strategy = Strategy::MultiTimeframeSignal.new(
    ema_1h_short: 21,
    ema_1h_long: 50,
    ema_15m: 21,
    ema_5m: 13,
    ema_1m: 8,
    tp_target: day_trading? ? 0.004 : 0.006,
    sl_target: day_trading? ? 0.003 : 0.004
  )
  
  TradingPair.enabled.find_each do |pair|
    signal = strategy.signal(symbol: pair.product_id, equity_usd: equity_usd)
    
    if signal
      # Create signal alert
      SignalAlert.create_entry_signal!(
        symbol: signal[:symbol],
        side: signal[:side],
        strategy_name: "multi_timeframe_signal",
        confidence: signal[:confidence],
        entry_price: signal[:price],
        stop_loss: signal[:stop_loss],
        take_profit: signal[:take_profit],
        quantity: signal[:quantity],
        timeframe: signal[:timeframe],
        metadata: signal[:metadata]
      )
      
      # Send notification
      SlackNotificationService.signal_generated(signal)
    end
  end
end
```

### Real-time Signal Evaluation
```ruby
# In RapidSignalEvaluationJob
def perform(product_id:, current_price:, asset:, day_trading: true)
  strategy = Strategy::MultiTimeframeSignal.new(
    # Day trading optimized parameters
    tp_target: 0.004,
    sl_target: 0.003,
    ema_5m: 8,
    ema_1m: 5,
    confidence_threshold: 75
  )
  
  signal = strategy.signal(
    symbol: product_id,
    equity_usd: ENV.fetch("SIGNAL_EQUITY_USD", "50000").to_f
  )
  
  if signal && should_execute_signal?(signal)
    # Execute through FuturesExecutor
    executor = Execution::FuturesExecutor.new
    executor.execute_signal(signal)
  end
end
```

---

**Next**: [Day Trading Guide](Day-Trading-Guide) | **Previous**: [Getting Started](Getting-Started) | **Up**: [Home](Home)