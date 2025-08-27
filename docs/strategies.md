# Trading Strategies Documentation

## Overview

The coinbase_futures_bot implements multiple trading strategies designed for cryptocurrency futures markets. Each strategy incorporates technical analysis, risk management, and sentiment filtering to generate trading signals.

**Important**: This system exclusively trades current month futures contracts (e.g., BIT-29AUG25-CDE, ET-29AUG25-CDE) and does not support perpetual contracts. All strategies include automatic contract resolution and rollover management.

## Strategy Architecture

### Strategy Interface

All strategies implement a common interface for consistency:

```ruby
module Strategy
  class StrategyName
    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    def signal(symbol:, equity_usd: 10_000.0)
      # Returns: { side:, price:, quantity:, tp:, sl:, confidence: } or nil
    end
  end
end
```

### Strategy Flow

```
Market Data → Technical Analysis → Sentiment Filter → Risk Management → Signal Generation
     ↓              ↓                    ↓                  ↓              ↓
  OHLCV Data    EMA/Indicators    Z-Score Threshold    Position Size    Order Parameters
```

## Implemented Strategies

### 1. Multi-Timeframe Signal Strategy

**Location**: `app/services/strategy/multi_timeframe_signal.rb`

**Purpose**: Primary trading strategy using multiple timeframes for robust signal generation.

#### Strategy Logic

The strategy analyzes four different timeframes to identify high-probability trading opportunities:

1. **1-hour (1h)**: Dominant trend identification
2. **15-minute (15m)**: Intraday trend confirmation
3. **5-minute (5m)**: Entry trigger and short-term momentum
4. **1-minute (1m)**: Micro-timing for precise entry

#### Configuration Parameters

```ruby
DEFAULTS = {
  # EMA periods for different timeframes
  ema_1h_short: 12,        # Short-term 1h EMA
  ema_1h_long: 26,         # Long-term 1h EMA
  ema_15m: 21,             # 15m EMA for trend confirmation
  ema_5m: 13,              # 5m EMA for entry signals
  ema_1m: 8,               # 1m EMA for micro-timing

  # Minimum candles required per timeframe
  min_1h_candles: 80,      # ~3+ days of hourly data
  min_15m_candles: 120,    # ~30 hours of 15m data
  min_5m_candles: 100,     # ~8+ hours of 5m data
  min_1m_candles: 60,      # ~1 hour of 1m data

  # Risk management
  tp_target: 0.004,        # 40 basis points take profit
  sl_target: 0.003,        # 30 basis points stop loss
  maker_fee: 0.0005,       # 5 basis points maker fee
  slippage: 0.0002,        # 2 basis points slippage
  risk_fraction: 0.005,    # 0.5% of equity at risk per trade

  # Futures-specific settings
  contract_size_usd: 100.0, # USD value per contract
  max_position_size: 5,     # Maximum contracts
  min_position_size: 1      # Minimum contracts
}
```

#### Signal Generation Process

##### 1. Trend Analysis (1h)
```ruby
# Determine dominant trend using 1h EMAs
closes_1h = candles_1h.map { |c| c.close.to_f }
ema1h_short = ema(closes_1h, ema_1h_short)
ema1h_long = ema(closes_1h, ema_1h_long)
trend = ema1h_short > ema1h_long ? :up : :down
```

##### 2. Trend Confirmation (15m)
```ruby
# Confirm intraday direction
closes_15m = candles_15m.map { |c| c.close.to_f }
ema15 = ema(closes_15m, ema_15m)
# Price action relative to 15m EMA confirms trend
```

##### 3. Entry Trigger (5m)
```ruby
# Short-term momentum for entry
closes_5m = candles_5m.map { |c| c.close.to_f }
ema5 = ema(closes_5m, ema_5m)
# Look for pullback-and-reclaim patterns
```

##### 4. Micro-Timing (1m)
```ruby
# Precise entry timing
closes_1m = candles_1m.map { |c| c.close.to_f }
ema1 = ema(closes_1m, ema_1m)
# Fine-tune entry based on 1m momentum
```

#### Entry Conditions

**Long Entry**:
- 1h trend is bullish (short EMA > long EMA)
- 15m price confirms bullish structure
- 5m shows pullback to EMA followed by reclaim
- 1m confirms momentum in direction
- Sentiment z-score alignment (if enabled)

**Short Entry**:
- 1h trend is bearish (short EMA < long EMA)
- 15m price confirms bearish structure
- 5m shows rejection from EMA resistance
- 1m confirms momentum in direction
- Sentiment z-score alignment (if enabled)

#### Risk Management

##### Position Sizing
```ruby
def calculate_position_size(equity_usd, entry_price, stop_loss)
  risk_amount = equity_usd * risk_fraction
  risk_per_contract = (entry_price - stop_loss).abs * contract_size_usd
  position_size = (risk_amount / risk_per_contract).floor

  # Clamp to min/max position size
  [[position_size, min_position_size].max, max_position_size].min
end
```

##### Stop Loss and Take Profit
```ruby
# Calculate based on entry price and targets
stop_loss = entry_price * (1 - sl_target)  # For longs
take_profit = entry_price * (1 + tp_target) # For longs

# Adjust for break-even after fees
break_even = CostModel.break_even_exit(
  entry_price: entry_price,
  fee_rate: maker_fee,
  slippage_rate: slippage
)
```

#### Sentiment Integration

The strategy integrates with sentiment analysis when enabled:

```ruby
def sentiment_gate_passed?(symbol, signal_direction)
  return true unless ENV['SENTIMENT_ENABLE'] == 'true'

  z_score = latest_sentiment_z_score(symbol, window: '15m')
  threshold = ENV.fetch('SENTIMENT_Z_THRESHOLD', '1.2').to_f

  case signal_direction
  when :long
    z_score >= threshold  # Positive sentiment for longs
  when :short
    z_score <= -threshold # Negative sentiment for shorts
  end
end
```

### 2. Spot-Driven Strategy

**Location**: `app/services/strategy/spot_driven_strategy.rb`

**Purpose**: Generates signals based on spot market analysis with sentiment filtering.

#### Strategy Logic

This strategy serves as a framework for spot-to-futures arbitrage and sentiment-based trading:

```ruby
def generate_signals(product_ids: ["BTC-USD", "ETH-USD"])
  signals = {}
  product_ids.each do |product_id|
    z_score = latest_sentiment_z(product_id, window: "15m")
    base_signal = base_strategy_signal(product_id)
    signals[product_id] = apply_sentiment_gate(base_signal, z_score)
  end
  signals
end
```

#### Sentiment Filtering

```ruby
def apply_sentiment_gate(base_signal, z_score)
  threshold = ENV.fetch("SENTIMENT_Z_THRESHOLD", "1.2").to_f

  if z_score.abs < threshold
    :flat  # No position if sentiment not strong enough
  else
    base_signal  # Allow signal if sentiment confirms
  end
end
```

#### Current Implementation

The base strategy currently returns `:flat` signals, serving as a template for:
- Spot-futures basis trading
- News-driven trading strategies
- Sentiment-momentum strategies

**Note**: This project focuses exclusively on current month futures contracts, not perpetual contracts.

### 3. Pullback Strategy (1h)

**Location**: `app/services/strategy/pullback_1h.rb`

**Purpose**: Trend-following strategy that enters on pullbacks to key moving averages.

#### Strategy Configuration

```ruby
DEFAULTS = {
  maker_fee: 0.0005,      # 5 bps maker fee
  slippage: 0.0002,       # 2 bps slippage
  tp_margin: 0.001,       # 10 bps margin above break-even
  tp_target: 0.006,       # 60 bps take profit target
  sl_target: 0.004,       # 40 bps stop loss
  min_candles: 50,        # Minimum data requirement
  ema_short: 12,          # Short EMA period
  ema_long: 50            # Long EMA period
}
```

#### Entry Logic

```ruby
def signal(candles:, symbol:, equity_usd: 1000.0)
  # Trend analysis
  uptrend = last.close.to_f > ema_long
  pullback = last.low.to_f <= ema_short && last.close.to_f >= ema_short

  # Confirmation filters
  volume_confirmation = volume_increasing?(candles)
  momentum_confirmation = momentum_positive?(closes)

  # Entry only if all conditions met
  return nil unless uptrend && pullback && volume_confirmation && momentum_confirmation

  # Calculate position parameters
  {
    side: :buy,
    price: entry_price,
    quantity: position_size,
    tp: take_profit_level,
    sl: stop_loss_level,
    confidence: confidence_score
  }
end
```

#### Confirmation Filters

##### Volume Confirmation
```ruby
def volume_increasing?(candles)
  recent_volumes = candles.last(3).map { |c| c.volume.to_f }
  recent_volumes.last > recent_volumes.first
end
```

##### Momentum Confirmation
```ruby
def momentum_positive?(closes)
  recent_closes = closes.last(5)
  recent_closes.last > recent_closes.first
end
```

#### Backtesting Framework

The strategy includes built-in backtesting capabilities:

```ruby
def backtest(candles:, symbol:, equity_usd: 1000.0)
  results = []
  current_equity = equity_usd

  (min_candles..candles.size-1).each do |i|
    test_candles = candles[0..i]
    signal = signal(candles: test_candles, symbol: symbol, equity_usd: current_equity)

    if signal
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
```

## Strategy Integration

### Signal Generation Job

Strategies are executed through the `GenerateSignalsJob`:

```ruby
class GenerateSignalsJob < ApplicationJob
  def perform(equity_usd: default_equity_usd)
    strategy = Strategy::MultiTimeframeSignal.new(
      ema_1h_short: 21,
      ema_1h_long: 50,
      ema_15m: 21,
      min_1h_candles: 60,
      min_15m_candles: 80
    )

    TradingPair.enabled.find_each do |pair|
      signal = strategy.signal(symbol: pair.product_id, equity_usd: equity_usd)
      process_signal(pair, signal) if signal
    end
  end
end
```

### Paper Trading Integration

Strategies are tested through the paper trading system:

```ruby
class PaperTradingJob < ApplicationJob
  def perform
    simulator = PaperTrading::ExchangeSimulator.new
    strategy = Strategy::MultiTimeframeSignal.new

    TradingPair.enabled.find_each do |pair|
      signal = strategy.signal(symbol: pair.product_id, equity_usd: simulator.equity_usd)

      if signal
        simulator.place_limit(
          symbol: pair.product_id,
          side: signal[:side],
          price: signal[:price],
          quantity: signal[:quantity],
          tp: signal[:tp],
          sl: signal[:sl]
        )
      end
    end
  end
end
```

## Technical Indicators

### Exponential Moving Average (EMA)

All strategies use a consistent EMA calculation:

```ruby
def ema(values, period)
  k = 2.0 / (period + 1)  # Smoothing factor
  ema = values.first       # Initialize with first value

  values.each do |value|
    ema = value * k + ema * (1 - k)
  end

  ema
end
```

### Volume Analysis

Volume confirmation helps filter false signals:

```ruby
def volume_confirmation?(candles, periods: 3)
  volumes = candles.last(periods).map { |c| c.volume.to_f }
  current_volume = volumes.last
  average_volume = volumes[0..-2].sum / (periods - 1)

  current_volume > average_volume * 1.2  # 20% above average
end
```

### Momentum Indicators

Simple momentum calculation for trend confirmation:

```ruby
def momentum(closes, periods: 5)
  return 0 if closes.size < periods

  current = closes.last
  previous = closes[-periods]

  ((current - previous) / previous) * 100
end
```

## Risk Management Framework

### Position Sizing Models

#### Fixed Fractional Model
```ruby
def fixed_fractional_sizing(equity_usd:, risk_fraction: 0.01, entry_price:, stop_loss:)
  risk_amount = equity_usd * risk_fraction
  risk_per_unit = (entry_price - stop_loss).abs

  return 0 if risk_per_unit <= 0

  (risk_amount / risk_per_unit).floor(6)
end
```

#### Volatility-Adjusted Sizing
```ruby
def volatility_adjusted_sizing(candles:, equity_usd:, target_volatility: 0.02)
  returns = calculate_returns(candles)
  realized_volatility = standard_deviation(returns)

  volatility_scalar = target_volatility / realized_volatility
  base_size = equity_usd * 0.01  # 1% base allocation

  (base_size * volatility_scalar).floor(6)
end
```

### Stop Loss Strategies

#### ATR-Based Stops
```ruby
def atr_stop_loss(candles:, entry_price:, atr_multiplier: 2.0, direction: :long)
  atr_value = average_true_range(candles, period: 14)

  case direction
  when :long
    entry_price - (atr_value * atr_multiplier)
  when :short
    entry_price + (atr_value * atr_multiplier)
  end
end
```

#### Percentage-Based Stops
```ruby
def percentage_stop_loss(entry_price:, stop_percentage: 0.02, direction: :long)
  case direction
  when :long
    entry_price * (1 - stop_percentage)
  when :short
    entry_price * (1 + stop_percentage)
  end
end
```

## Strategy Performance Monitoring

### Metrics Collection

```ruby
class StrategyMetrics
  def self.track_signal(strategy_name, symbol, signal)
    return unless signal

    StatsD.increment("strategy.#{strategy_name}.signals",
                    tags: ["symbol:#{symbol}", "side:#{signal[:side]}"])
    StatsD.histogram("strategy.#{strategy_name}.confidence",
                    signal[:confidence], tags: ["symbol:#{symbol}"])
  end

  def self.track_execution(strategy_name, symbol, result)
    StatsD.histogram("strategy.#{strategy_name}.pnl",
                    result[:pnl], tags: ["symbol:#{symbol}"])
    StatsD.increment("strategy.#{strategy_name}.trades",
                    tags: ["symbol:#{symbol}", "outcome:#{result[:outcome]}"])
  end
end
```

### Performance Analysis

```ruby
class StrategyAnalyzer
  def analyze_performance(trades)
    {
      total_trades: trades.count,
      winning_trades: trades.count { |t| t[:pnl] > 0 },
      win_rate: win_rate(trades),
      average_win: average_win(trades),
      average_loss: average_loss(trades),
      profit_factor: profit_factor(trades),
      sharpe_ratio: sharpe_ratio(trades),
      max_drawdown: max_drawdown(trades)
    }
  end

  private

  def win_rate(trades)
    return 0 if trades.empty?
    (trades.count { |t| t[:pnl] > 0 }.to_f / trades.count) * 100
  end

  def profit_factor(trades)
    wins = trades.select { |t| t[:pnl] > 0 }
    losses = trades.select { |t| t[:pnl] < 0 }

    return 0 if losses.empty?

    total_wins = wins.sum { |t| t[:pnl] }
    total_losses = losses.sum { |t| t[:pnl].abs }

    total_wins / total_losses
  end
end
```

## Strategy Development Guidelines

### Adding New Strategies

1. **Create Strategy Class**:
```ruby
module Strategy
  class NewStrategy
    DEFAULTS = {
      # Configuration parameters
    }.freeze

    def initialize(config = {})
      @config = DEFAULTS.merge(config)
    end

    def signal(symbol:, equity_usd: 10_000.0)
      # Strategy logic
      # Return signal hash or nil
    end
  end
end
```

2. **Implement Required Methods**:
- `signal(symbol:, equity_usd:)` - Core signal generation
- `initialize(config)` - Strategy configuration
- Private helper methods for calculations

3. **Add Tests**:
```ruby
RSpec.describe Strategy::NewStrategy do
  let(:strategy) { described_class.new }

  describe '#signal' do
    # Test cases for different market conditions
  end
end
```

4. **Integration**:
- Add to `GenerateSignalsJob`
- Configure in `PaperTradingJob`
- Update documentation

### Best Practices

#### Strategy Design
- Keep strategies focused and modular
- Use consistent parameter naming
- Implement proper error handling
- Include confidence scoring

#### Testing
- Test edge cases and insufficient data
- Use VCR for external data dependencies
- Mock time-dependent functions
- Test both signal generation and nil returns

#### Documentation
- Document strategy logic clearly
- Explain parameter choices
- Include example configurations
- Document expected performance characteristics

#### Risk Management
- Always implement position sizing
- Include multiple exit strategies
- Consider correlation between strategies
- Monitor performance metrics

## Configuration and Tuning

### Strategy Parameters

#### Multi-Timeframe Signal
```bash
# Environment-based configuration
STRATEGY_EMA_1H_SHORT=21
STRATEGY_EMA_1H_LONG=50
STRATEGY_TP_TARGET=0.004
STRATEGY_SL_TARGET=0.003
STRATEGY_RISK_FRACTION=0.005
```

#### Runtime Configuration
```ruby
strategy = Strategy::MultiTimeframeSignal.new({
  ema_1h_short: ENV.fetch('STRATEGY_EMA_1H_SHORT', 21).to_i,
  ema_1h_long: ENV.fetch('STRATEGY_EMA_1H_LONG', 50).to_i,
  tp_target: ENV.fetch('STRATEGY_TP_TARGET', 0.004).to_f,
  sl_target: ENV.fetch('STRATEGY_SL_TARGET', 0.003).to_f
})
```

### Parameter Optimization

#### Grid Search
```ruby
class ParameterOptimizer
  def optimize_parameters(strategy_class, historical_data, param_ranges)
    best_params = nil
    best_performance = -Float::INFINITY

    param_combinations = generate_combinations(param_ranges)

    param_combinations.each do |params|
      strategy = strategy_class.new(params)
      performance = backtest_strategy(strategy, historical_data)

      if performance[:sharpe_ratio] > best_performance
        best_performance = performance[:sharpe_ratio]
        best_params = params
      end
    end

    { params: best_params, performance: best_performance }
  end
end
```

#### Walk-Forward Analysis
```ruby
def walk_forward_analysis(strategy_class, data, optimization_window: 30.days)
  results = []

  (optimization_window...data.length).step(7.days) do |i|
    training_data = data[(i-optimization_window)...i]
    test_data = data[i...(i+7.days)]

    # Optimize on training data
    optimal_params = optimize_parameters(strategy_class, training_data)

    # Test on out-of-sample data
    strategy = strategy_class.new(optimal_params)
    test_results = backtest_strategy(strategy, test_data)

    results << test_results
  end

  results
end
```

## Troubleshooting

### Common Issues

#### Insufficient Data
```ruby
def validate_data_requirements
  required_candles = {
    '1h' => min_1h_candles,
    '15m' => min_15m_candles,
    '5m' => min_5m_candles,
    '1m' => min_1m_candles
  }

  required_candles.each do |timeframe, min_count|
    actual_count = Candle.where(symbol: symbol, timeframe: timeframe).count
    if actual_count < min_count
      Rails.logger.warn("Insufficient #{timeframe} data: #{actual_count}/#{min_count}")
      return false
    end
  end

  true
end
```

#### Signal Quality Issues
```ruby
def debug_signal_generation(symbol)
  {
    data_availability: check_data_availability(symbol),
    trend_analysis: analyze_trend_components(symbol),
    sentiment_status: check_sentiment_data(symbol),
    recent_signals: recent_signal_history(symbol)
  }
end
```

#### Performance Issues
```ruby
def profile_strategy_performance
  start_time = Time.current

  result = yield

  duration = Time.current - start_time
  Rails.logger.info("Strategy execution time: #{duration}s")

  if duration > 5.seconds
    Rails.logger.warn("Strategy execution slow: #{duration}s")
  end

  result
end
```

### Debug Commands

```bash
# Test strategy in console
bin/rails console
strategy = Strategy::MultiTimeframeSignal.new
signal = strategy.signal(symbol: 'BTC-USD', equity_usd: 10_000)

# Check data availability
Candle.where(symbol: 'BTC-USD').group(:timeframe).count

# Generate signals for all pairs
GenerateSignalsJob.perform_now(equity_usd: 5_000)

# Paper trading simulation
PaperTradingJob.perform_now
```
