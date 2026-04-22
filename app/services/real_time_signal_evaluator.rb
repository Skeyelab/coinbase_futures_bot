# frozen_string_literal: true

# Real-time signal evaluator that continuously monitors market conditions
# and generates alerts when trading opportunities are detected
class RealTimeSignalEvaluator
  attr_reader :logger, :strategies, :last_evaluation

  def initialize(logger: Rails.logger)
    @logger = logger
    @strategies = load_strategies
    @last_evaluation = {}

    config = Rails.application.config.real_time_signals
    @evaluation_interval = TradingConfiguration.evaluation_interval_seconds.seconds
    @min_confidence_threshold = TradingConfiguration.min_confidence
    @deduplication_window = config[:deduplication_window]
    @max_signals_per_hour = TradingConfiguration.max_signals_per_hour
  end

  # Evaluate all enabled trading pairs for signals
  def evaluate_all_pairs
    return unless should_evaluate?

    enabled_pairs = TradingPair.enabled

    if enabled_pairs.empty?
      @logger.warn("[RTSE] No enabled trading pairs found. Run market data sync first.")
      @logger.info("[RTSE] To sync products: bin/rake market_data:sync_products")
      return
    end

    @logger.info("[RTSE] Evaluating #{enabled_pairs.count} enabled trading pairs")

    enabled_pairs.find_each do |pair|
      evaluate_pair(pair)
    end

    @last_evaluation[:all] = Time.current.utc
  end

  # Evaluate a specific trading pair for signals
  def evaluate_pair(trading_pair)
    symbol = resolve_symbol(trading_pair.product_id)
    equity_usd = TradingConfiguration.signal_equity_usd

    @strategies.each do |strategy_name, strategy|
      evaluate_strategy_for_symbol(strategy_name, strategy, symbol, equity_usd)
    end

    @last_evaluation[symbol] = Time.current.utc
  end

  # Check if we should run evaluation based on timing constraints
  def should_evaluate?(symbol = :all)
    last_eval = @last_evaluation[symbol]
    return true unless last_eval

    Time.current.utc - last_eval >= @evaluation_interval
  end

  private

  def load_strategies
    config = Rails.application.config.real_time_signals
    strategy_config = config[:strategies]["MultiTimeframeSignal"]

    {
      "MultiTimeframeSignal" => Strategy::MultiTimeframeSignal.new(
        ema_1h_short: strategy_config[:ema_1h_short],
        ema_1h_long: strategy_config[:ema_1h_long],
        ema_15m: strategy_config[:ema_15m],
        ema_5m: strategy_config[:ema_5m],
        ema_1m: strategy_config[:ema_1m],
        min_1h_candles: strategy_config[:min_1h_candles],
        min_15m_candles: strategy_config[:min_15m_candles],
        min_5m_candles: strategy_config[:min_5m_candles],
        min_1m_candles: strategy_config[:min_1m_candles],
        tp_target: strategy_config[:tp_target],
        sl_target: strategy_config[:sl_target],
        risk_fraction: strategy_config[:risk_fraction],
        contract_size_usd: strategy_config[:contract_size_usd],
        max_position_size: strategy_config[:max_position_size],
        min_position_size: strategy_config[:min_position_size]
      )
    }
  end

  def evaluate_strategy_for_symbol(strategy_name, strategy, symbol, equity_usd)
    return unless has_sufficient_data?(symbol)

    signal = strategy.signal(symbol: symbol, equity_usd: equity_usd)

    create_signal_alert(strategy_name, symbol, signal) if signal && valid_signal?(signal)
  rescue => e
    @logger.error("[RTSE] Error evaluating #{strategy_name} for #{symbol}: #{e.message}")
    @logger.error(e.backtrace.join("\n"))
  end

  def valid_signal?(signal)
    return false unless signal.is_a?(Hash)
    return false unless signal[:side] && signal[:price] && signal[:confidence]

    # Check minimum confidence threshold
    signal[:confidence].to_f >= @min_confidence_threshold
  end

  def has_sufficient_data?(symbol)
    # Check if we have recent candle data for all required timeframes
    required_timeframes = %w[1h 15m 5m 1m]
    required_timeframes.all? do |timeframe|
      Candle.for_symbol(symbol).where(timeframe: timeframe)
        .where("timestamp >= ?", 2.hours.ago).exists?
    end
  end

  def create_signal_alert(strategy_name, symbol, signal)
    return unless should_create_signal?(strategy_name, symbol, signal)

    SignalAlert.create_entry_signal!(
      symbol: symbol,
      side: signal[:side],
      strategy_name: strategy_name,
      confidence: signal[:confidence],
      entry_price: signal[:price],
      stop_loss: signal[:sl],
      take_profit: signal[:tp],
      quantity: signal[:quantity],
      timeframe: detect_timeframe(signal),
      metadata: build_metadata(signal),
      strategy_data: signal.except(:side, :price, :sl, :tp, :quantity, :confidence)
    )

    @logger.info("[RTSE] Created signal alert: #{strategy_name} #{symbol} #{signal[:side]}@#{signal[:price]} conf:#{signal[:confidence]}%")

    # Broadcast the signal if broadcaster is available
    broadcast_signal(signal) if defined?(SignalBroadcaster)
  rescue => e
    @logger.error("[RTSE] Failed to create signal alert: #{e.message}")
  end

  def should_create_signal?(strategy_name, symbol, signal)
    # Check rate limiting
    return false if signal_rate_limited?(strategy_name, symbol)

    # Check for duplicate signals within deduplication window
    return false if duplicate_signal?(strategy_name, symbol, signal)

    true
  end

  def signal_rate_limited?(strategy_name, symbol)
    recent_signals = SignalAlert.where(strategy_name: strategy_name, symbol: symbol)
      .where("alert_timestamp >= ?", 1.hour.ago)
      .count

    if recent_signals >= @max_signals_per_hour
      @logger.debug("[RTSE] Rate limited: #{recent_signals} signals in last hour for #{strategy_name}:#{symbol}")
      return true
    end

    false
  end

  def duplicate_signal?(strategy_name, symbol, signal)
    # Look for similar signals within the deduplication window
    SignalAlert.where(
      strategy_name: strategy_name,
      symbol: symbol,
      side: signal[:side],
      signal_type: "entry",
      alert_status: "active"
    ).where("alert_timestamp >= ?", @deduplication_window.ago)
      .where("confidence >= ?", signal[:confidence].to_f - 10) # Allow 10% confidence difference
      .exists?
  end

  def detect_timeframe(signal)
    # Try to detect timeframe from strategy data or signal metadata
    signal[:timeframe] || signal.dig(:strategy_data, :timeframe) || "15m"
  end

  def build_metadata(signal)
    {
      evaluation_timestamp: Time.current.utc.iso8601,
      strategy_version: "1.0",
      market_conditions: analyze_market_conditions(signal),
      risk_metrics: calculate_risk_metrics(signal)
    }
  end

  def analyze_market_conditions(signal)
    # Analyze current market conditions for the signal
    symbol = resolve_symbol_from_signal(signal)
    return {} unless symbol

    conditions = {}

    # Check volatility across timeframes
    %w[1h 15m 5m 1m].each do |timeframe|
      candles = Candle.for_symbol(symbol).where(timeframe: timeframe)
        .order(:timestamp).last(20)
      next unless candles.size >= 10

      prices = candles.map(&:close)
      volatility = calculate_volatility(prices)
      conditions["#{timeframe}_volatility"] = volatility.round(4)
    end

    conditions
  end

  def calculate_risk_metrics(signal)
    return {} unless signal[:price] && signal[:sl]

    risk_per_unit = (signal[:price].to_f - signal[:sl].to_f).abs
    risk_reward_ratio = calculate_risk_reward_ratio(signal)

    {
      risk_per_unit: risk_per_unit.round(4),
      risk_reward_ratio: risk_reward_ratio.round(2),
      position_size_pct: ((signal[:quantity] || 1) * 100.0 / 100).round(2) # Assuming $100 per contract
    }
  end

  def calculate_risk_reward_ratio(signal)
    return 0 unless signal[:price] && signal[:sl] && signal[:tp]

    risk = (signal[:price].to_f - signal[:sl].to_f).abs
    reward = (signal[:tp].to_f - signal[:price].to_f).abs

    reward / risk
  end

  def calculate_volatility(prices)
    return 0 if prices.size < 2

    returns = prices.each_cons(2).map { |p1, p2| (p2 - p1) / p1.to_f }
    standard_deviation(returns).abs
  end

  def standard_deviation(values)
    return 0 if values.empty?

    mean = values.sum / values.size.to_f
    variance = values.sum { |v| (v - mean)**2 } / values.size.to_f
    Math.sqrt(variance)
  end

  def resolve_symbol(symbol)
    # Convert asset symbols to current month contracts
    return symbol unless symbol.match?(/^(BTC|ETH)(-USD)?$/)

    asset = symbol.match(/^(BTC|ETH)/)[1]
    contract_manager = MarketData::FuturesContractManager.new
    contract_manager.best_available_contract(asset) || symbol
  end

  def resolve_symbol_from_signal(signal)
    # Extract symbol from signal data
    signal[:symbol] || signal.dig(:strategy_data, :symbol)
  end

  def broadcast_signal(signal)
    SignalBroadcaster.broadcast(signal)
  rescue => e
    @logger.error("[RTSE] Failed to broadcast signal: #{e.message}")
  end
end
