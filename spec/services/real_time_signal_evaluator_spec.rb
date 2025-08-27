# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealTimeSignalEvaluator, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:evaluator) { described_class.new(logger: logger) }
  let(:trading_pair) { create(:trading_pair, product_id: "BTC-USD", enabled: true) }
  let(:strategy_config) do
    {
      ema_1h_short: 5,
      ema_1h_long: 20,
      ema_15m: 8,
      ema_5m: 5,
      ema_1m: 3,
      min_1h_candles: 80,
      min_15m_candles: 120,
      min_5m_candles: 100,
      min_1m_candles: 60,
      tp_target: 0.02,
      sl_target: 0.01,
      risk_fraction: 0.02,
      contract_size_usd: 100,
      max_position_size: 15,
      min_position_size: 5
    }
  end

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)

    # Mock Rails configuration
    config = double("config")
    real_time_signals_config = {
      evaluation_interval: 30,
      min_confidence_threshold: 65,
      deduplication_window: 5.minutes,
      max_signals_per_hour: 8,
      strategies: {
        "MultiTimeframeSignal" => strategy_config
      }
    }
    allow(config).to receive(:real_time_signals).and_return(real_time_signals_config)
    allow(Rails.application).to receive(:config).and_return(config)

    # Clear any existing signal alerts
    SignalAlert.delete_all
  end

  describe "#initialize" do
    it "initializes with provided logger" do
      expect(evaluator.logger).to eq(logger)
    end

    it "loads strategies from configuration" do
      expect(evaluator.strategies).to be_a(Hash)
      expect(evaluator.strategies).to have_key("MultiTimeframeSignal")
      expect(evaluator.strategies["MultiTimeframeSignal"]).to be_a(Strategy::MultiTimeframeSignal)
    end

    it "sets configuration values from Rails config" do
      expect(evaluator.instance_variable_get(:@evaluation_interval)).to eq(30.seconds)
      expect(evaluator.instance_variable_get(:@min_confidence_threshold)).to eq(65)
      expect(evaluator.instance_variable_get(:@deduplication_window)).to eq(5.minutes)
      expect(evaluator.instance_variable_get(:@max_signals_per_hour)).to eq(8)
    end

    it "uses Rails.logger as default" do
      evaluator = described_class.new
      expect(evaluator.logger).to eq(Rails.logger)
    end
  end

  describe "#evaluate_all_pairs" do
    context "when no enabled trading pairs exist" do
      before do
        TradingPair.update_all(enabled: false)
      end

      it "logs warning and returns early" do
        expect(logger).to receive(:warn).with(/No enabled trading pairs found/)
        expect(logger).to receive(:info).with(/To sync products/)

        evaluator.evaluate_all_pairs
      end

      it "does not evaluate any pairs" do
        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)

        expect(evaluator).not_to receive(:evaluate_pair)

        evaluator.evaluate_all_pairs
      end
    end

    context "when enabled trading pairs exist" do
      before do
        trading_pair
      end

      it "evaluates all enabled pairs" do
        expect(evaluator).to receive(:evaluate_pair).with(trading_pair)

        evaluator.evaluate_all_pairs
      end

      it "logs the number of pairs being evaluated" do
        expect(logger).to receive(:info).with(/Evaluating 1 enabled trading pairs/)

        evaluator.evaluate_all_pairs
      end

      it "updates last evaluation timestamp" do
        evaluator.evaluate_all_pairs

        expect(evaluator.last_evaluation[:all]).to be_within(1.second).of(Time.current.utc)
      end
    end

    context "with evaluation timing constraints" do
      before do
        trading_pair
        evaluator.instance_variable_set(:@last_evaluation, {all: 10.seconds.ago})
      end

      it "skips evaluation when within interval" do
        evaluator.instance_variable_set(:@evaluation_interval, 30.seconds)

        expect(evaluator).not_to receive(:evaluate_pair)

        evaluator.evaluate_all_pairs
      end

      it "proceeds with evaluation when interval has passed" do
        evaluator.instance_variable_set(:@evaluation_interval, 5.seconds)

        expect(evaluator).to receive(:evaluate_pair)

        evaluator.evaluate_all_pairs
      end
    end
  end

  describe "#evaluate_pair" do
    let(:symbol) { "BTC-DEC2024" }
    let(:equity_usd) { 5000.0 }

    before do
      allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "10000").and_return(equity_usd.to_s)
    end

    it "resolves symbol using futures contract manager" do
      contract_manager = instance_double(MarketData::FuturesContractManager)
      allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
      allow(contract_manager).to receive(:best_available_contract).and_return(symbol)

      expect(evaluator).to receive(:evaluate_strategy_for_symbol).with(
        "MultiTimeframeSignal",
        anything,
        symbol,
        equity_usd
      )

      evaluator.evaluate_pair(trading_pair)
    end

    it "evaluates all configured strategies" do
      allow(evaluator).to receive(:resolve_symbol).and_return(symbol)
      allow(evaluator).to receive(:has_sufficient_data?).and_return(true)

      strategy = evaluator.strategies["MultiTimeframeSignal"]
      expect(strategy).to receive(:signal).with(symbol: symbol, equity_usd: equity_usd)

      evaluator.evaluate_pair(trading_pair)
    end

    it "updates last evaluation timestamp for the symbol" do
      allow(evaluator).to receive(:resolve_symbol).and_return(symbol)
      allow(evaluator).to receive(:has_sufficient_data?).and_return(false) # Skip evaluation

      evaluator.evaluate_pair(trading_pair)

      expect(evaluator.last_evaluation[symbol]).to be_within(1.second).of(Time.current.utc)
    end
  end

  describe "#should_evaluate?" do
    it "returns true when no previous evaluation exists" do
      expect(evaluator.should_evaluate?).to be true
      expect(evaluator.should_evaluate?(:btc)).to be true
    end

    it "returns true when evaluation interval has passed" do
      evaluator.instance_variable_set(:@evaluation_interval, 30.seconds)
      evaluator.instance_variable_set(:@last_evaluation, {all: 45.seconds.ago})

      expect(evaluator.should_evaluate?).to be true
    end

    it "returns false when within evaluation interval" do
      evaluator.instance_variable_set(:@evaluation_interval, 30.seconds)
      evaluator.instance_variable_set(:@last_evaluation, {all: 10.seconds.ago})

      expect(evaluator.should_evaluate?).to be false
    end

    it "handles symbol-specific evaluations" do
      evaluator.instance_variable_set(:@last_evaluation, {"BTC-USD": 10.seconds.ago})

      expect(evaluator.should_evaluate?("BTC-USD")).to be false
    end
  end

  describe "#valid_signal?" do
    it "returns false for non-hash signals" do
      expect(evaluator.send(:valid_signal?, nil)).to be false
      expect(evaluator.send(:valid_signal?, "invalid")).to be false
      expect(evaluator.send(:valid_signal?, [])).to be false
    end

    it "returns false when required fields are missing" do
      expect(evaluator.send(:valid_signal?, {})).to be false
      expect(evaluator.send(:valid_signal?, {side: "long"})).to be false
      expect(evaluator.send(:valid_signal?, {side: "long", price: 50000})).to be false
    end

    it "returns false when confidence is below threshold" do
      signal = {side: "long", price: 50000, confidence: 50}
      evaluator.instance_variable_set(:@min_confidence_threshold, 65)

      expect(evaluator.send(:valid_signal?, signal)).to be false
    end

    it "returns true for valid signals above threshold" do
      signal = {side: "long", price: 50000, confidence: 75}
      evaluator.instance_variable_set(:@min_confidence_threshold, 65)

      expect(evaluator.send(:valid_signal?, signal)).to be true
    end

    it "handles string confidence values" do
      signal = {side: "long", price: 50000, confidence: "80.5"}

      expect(evaluator.send(:valid_signal?, signal)).to be true
    end
  end

  describe "#has_sufficient_data?" do
    let(:symbol) { "BTC-USD" }

    context "when all required timeframes have recent data" do
      before do
        %w[1h 15m 5m 1m].each do |timeframe|
          create(:candle, symbol: symbol, timeframe: timeframe, timestamp: 1.hour.ago)
        end
      end

      it "returns true" do
        expect(evaluator.send(:has_sufficient_data?, symbol)).to be true
      end
    end

    context "when some timeframe is missing recent data" do
      before do
        %w[1h 15m 5m].each do |timeframe|
          create(:candle, symbol: symbol, timeframe: timeframe, timestamp: 1.hour.ago)
        end
        # No 1m candles
      end

      it "returns false" do
        expect(evaluator.send(:has_sufficient_data?, symbol)).to be false
      end
    end

    context "when data is too old" do
      before do
        %w[1h 15m 5m 1m].each do |timeframe|
          create(:candle, symbol: symbol, timeframe: timeframe, timestamp: 3.hours.ago)
        end
      end

      it "returns false" do
        expect(evaluator.send(:has_sufficient_data?, symbol)).to be false
      end
    end
  end

  describe "#signal_rate_limited?" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-USD" }

    context "when under rate limit" do
      it "returns false" do
        expect(evaluator.send(:signal_rate_limited?, strategy_name, symbol)).to be false
      end
    end

    context "when at rate limit" do
      before do
        evaluator.instance_variable_set(:@max_signals_per_hour, 3)
        3.times do
          create(:signal_alert,
            strategy_name: strategy_name,
            symbol: symbol,
            alert_timestamp: 30.minutes.ago)
        end
      end

      it "returns true" do
        expect(evaluator.send(:signal_rate_limited?, strategy_name, symbol)).to be true
      end

      it "logs rate limiting message" do
        expect(logger).to receive(:debug).with(/Rate limited: 3 signals/)

        evaluator.send(:signal_rate_limited?, strategy_name, symbol)
      end
    end
  end

  describe "#duplicate_signal?" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-USD" }
    let(:signal) { {side: "long", confidence: 75} }

    context "when no similar signals exist" do
      it "returns false" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be false
      end
    end

    context "when similar signal exists within deduplication window" do
      before do
        evaluator.instance_variable_set(:@deduplication_window, 10.minutes)
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "long",
          confidence: 70,
          alert_timestamp: 5.minutes.ago)
      end

      it "returns true" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be true
      end
    end

    context "when similar signal exists but outside deduplication window" do
      before do
        evaluator.instance_variable_set(:@deduplication_window, 5.minutes)
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "long",
          confidence: 75,
          alert_timestamp: 10.minutes.ago)
      end

      it "returns false" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be false
      end
    end

    context "when signal has different side" do
      before do
        evaluator.instance_variable_set(:@deduplication_window, 10.minutes)
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "short", # Different from signal side
          confidence: 75,
          alert_timestamp: 5.minutes.ago)
      end

      it "returns false" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be false
      end
    end
  end

  describe "#create_signal_alert" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-USD" }
    let(:signal) do
      {
        side: "long",
        price: 50000,
        confidence: 75,
        sl: 49000,
        tp: 52000,
        quantity: 10,
        timeframe: "15m",
        strategy_data: {ema_short: 49900, ema_long: 49800}
      }
    end

    context "when signal creation is allowed" do
      before do
        allow(evaluator).to receive(:should_create_signal?).and_return(true)
        allow(evaluator).to receive(:broadcast_signal)
      end

      it "creates a signal alert" do
        expect do
          evaluator.send(:create_signal_alert, strategy_name, symbol, signal)
        end.to change(SignalAlert, :count).by(1)
      end

      it "creates signal with correct attributes" do
        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

        alert = SignalAlert.last
        expect(alert.symbol).to eq(symbol)
        expect(alert.side).to eq("long")
        expect(alert.strategy_name).to eq(strategy_name)
        expect(alert.confidence).to eq(75)
        expect(alert.entry_price).to eq(50000)
        expect(alert.stop_loss).to eq(49000)
        expect(alert.take_profit).to eq(52000)
        expect(alert.quantity).to eq(10)
        expect(alert.timeframe).to eq("15m")
      end

      it "logs signal creation" do
        expect(logger).to receive(:info).with(/Created signal alert: MultiTimeframeSignal BTC-USD long@50000 conf:75%/)

        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)
      end

      it "broadcasts the signal if SignalBroadcaster is defined" do
        expect(evaluator).to receive(:broadcast_signal).with(signal)

        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)
      end
    end

    context "when signal creation is not allowed" do
      before do
        allow(evaluator).to receive(:should_create_signal?).and_return(false)
      end

      it "does not create a signal alert" do
        expect do
          evaluator.send(:create_signal_alert, strategy_name, symbol, signal)
        end.not_to change(SignalAlert, :count)
      end
    end

    context "when signal creation fails" do
      before do
        allow(evaluator).to receive(:should_create_signal?).and_return(true)
        allow(SignalAlert).to receive(:create_entry_signal!).and_raise(StandardError.new("Database error"))
      end

      it "logs the error" do
        expect(logger).to receive(:error).with(/Failed to create signal alert: Database error/)

        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)
      end
    end
  end

  describe "#detect_timeframe" do
    it "returns signal timeframe if present" do
      signal = {timeframe: "5m"}
      expect(evaluator.send(:detect_timeframe, signal)).to eq("5m")
    end

    it "returns timeframe from strategy_data if present" do
      signal = {strategy_data: {timeframe: "1h"}}
      expect(evaluator.send(:detect_timeframe, signal)).to eq("1h")
    end

    it "returns default timeframe if none found" do
      signal = {}
      expect(evaluator.send(:detect_timeframe, signal)).to eq("15m")
    end
  end

  describe "#build_metadata" do
    let(:signal) { {side: "long", price: 50000} }

    it "builds metadata with evaluation timestamp" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata).to have_key(:evaluation_timestamp)
      expect(metadata).to have_key(:strategy_version)
      expect(metadata).to have_key(:market_conditions)
      expect(metadata).to have_key(:risk_metrics)
    end

    it "includes evaluation timestamp in ISO format" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata[:evaluation_timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end
  end

  describe "#calculate_risk_reward_ratio" do
    it "calculates correct risk-reward ratio" do
      signal = {price: 50000, sl: 49000, tp: 52000}

      ratio = evaluator.send(:calculate_risk_reward_ratio, signal)

      # Risk = 1000, Reward = 2000, Ratio = 2.0
      expect(ratio).to eq(2.0)
    end

    it "returns 0 when required data is missing" do
      expect(evaluator.send(:calculate_risk_reward_ratio, {})).to eq(0)
      expect(evaluator.send(:calculate_risk_reward_ratio, {price: 50000})).to eq(0)
      expect(evaluator.send(:calculate_risk_reward_ratio, {price: 50000, sl: 49000})).to eq(0)
    end
  end

  describe "#calculate_volatility" do
    it "calculates volatility from price series" do
      prices = [100, 101, 102, 101, 103]

      volatility = evaluator.send(:calculate_volatility, prices)

      expect(volatility).to be_a(Float)
      expect(volatility).to be >= 0
    end

    it "returns 0 for insufficient data" do
      expect(evaluator.send(:calculate_volatility, [])).to eq(0)
      expect(evaluator.send(:calculate_volatility, [100])).to eq(0)
    end
  end

  describe "#resolve_symbol" do
    it "returns symbol unchanged if not BTC or ETH" do
      expect(evaluator.send(:resolve_symbol, "AAPL")).to eq("AAPL")
    end

    it "resolves BTC to current month contract" do
      contract_manager = instance_double(MarketData::FuturesContractManager)
      allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
      allow(contract_manager).to receive(:best_available_contract).and_return("BTC-DEC2024")

      expect(evaluator.send(:resolve_symbol, "BTC")).to eq("BTC-DEC2024")
      expect(evaluator.send(:resolve_symbol, "BTC-USD")).to eq("BTC-DEC2024")
    end

    it "resolves ETH to current month contract" do
      contract_manager = instance_double(MarketData::FuturesContractManager)
      allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
      allow(contract_manager).to receive(:best_available_contract).and_return("ETH-DEC2024")

      expect(evaluator.send(:resolve_symbol, "ETH")).to eq("ETH-DEC2024")
      expect(evaluator.send(:resolve_symbol, "ETH-USD")).to eq("ETH-DEC2024")
    end

    it "falls back to original symbol if contract manager returns nil" do
      contract_manager = instance_double(MarketData::FuturesContractManager)
      allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
      allow(contract_manager).to receive(:best_available_contract).and_return(nil)

      expect(evaluator.send(:resolve_symbol, "BTC")).to eq("BTC")
    end
  end

  describe "#broadcast_signal" do
    let(:signal) { {side: "long", price: 50000} }

    context "when SignalBroadcaster is available" do
      before do
        allow(SignalBroadcaster).to receive(:broadcast)
      end

      it "broadcasts the signal" do
        expect(SignalBroadcaster).to receive(:broadcast).with(signal)

        evaluator.send(:broadcast_signal, signal)
      end
    end

    context "when broadcasting fails" do
      before do
        allow(SignalBroadcaster).to receive(:broadcast).and_raise(StandardError.new("Broadcast error"))
      end

      it "logs the error" do
        expect(logger).to receive(:error).with(/Failed to broadcast signal: Broadcast error/)

        evaluator.send(:broadcast_signal, signal)
      end
    end
  end

  describe "error handling" do
    it "handles strategy evaluation errors gracefully" do
      strategy = instance_double(Strategy::MultiTimeframeSignal)
      evaluator.instance_variable_set(:@strategies, {"TestStrategy" => strategy})

      allow(strategy).to receive(:signal).and_raise(StandardError.new("Strategy error"))

      expect(logger).to receive(:error).with(/Error evaluating TestStrategy for BTC-USD: Strategy error/)
      expect(logger).to receive(:error) # backtrace

      evaluator.send(:evaluate_strategy_for_symbol, "TestStrategy", strategy, "BTC-USD", 5000)
    end
  end
end
