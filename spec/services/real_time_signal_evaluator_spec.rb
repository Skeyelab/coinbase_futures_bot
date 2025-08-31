# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealTimeSignalEvaluator, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:evaluator) { described_class.new(logger: logger) }

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)
  end

  describe "#initialize" do
    it "initializes with provided logger" do
      expect(evaluator.logger).to eq(logger)
    end

    it "loads strategies from configuration" do
      expect(evaluator.strategies).to be_a(Hash)
      expect(evaluator.strategies).to have_key("MultiTimeframeSignal")
    end

    it "uses Rails.logger as default" do
      evaluator = described_class.new
      expect(evaluator.logger).to eq(Rails.logger)
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
      expect(evaluator.send(:valid_signal?, {side: "long", price: 50_000})).to be false
    end

    it "returns false when confidence is below threshold" do
      signal = {side: "long", price: 50_000, confidence: 50}
      expect(evaluator.send(:valid_signal?, signal)).to be false
    end

    it "returns true for valid signals above threshold" do
      signal = {side: "long", price: 50_000, confidence: 75}
      expect(evaluator.send(:valid_signal?, signal)).to be true
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

  describe "#resolve_symbol" do
    it "returns symbol unchanged if not BTC or ETH" do
      expect(evaluator.send(:resolve_symbol, "AAPL")).to eq("AAPL")
    end

    it "resolves BTC to current futures contract" do
      result = evaluator.send(:resolve_symbol, "BTC")
      expect(result).to match(/^BIT-\d{2}[A-Z]{3}\d{2}-CDE$/)
    end

    it "resolves ETH to current futures contract" do
      result = evaluator.send(:resolve_symbol, "ETH")
      expect(result).to match(/^ET-\d{2}[A-Z]{3}\d{2}-CDE$/)
    end
  end

  describe "#calculate_risk_reward_ratio" do
    it "calculates correct risk-reward ratio" do
      signal = {price: 50_000, sl: 49_000, tp: 52_000}
      ratio = evaluator.send(:calculate_risk_reward_ratio, signal)
      expect(ratio).to eq(2.0)
    end

    it "returns 0 when required data is missing" do
      expect(evaluator.send(:calculate_risk_reward_ratio, {})).to eq(0)
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

  describe "#standard_deviation" do
    it "calculates standard deviation correctly" do
      values = [1, 2, 3, 4, 5]
      result = evaluator.send(:standard_deviation, values)
      expect(result).to be_within(0.01).of(1.41)
    end

    it "returns 0 for empty array" do
      expect(evaluator.send(:standard_deviation, [])).to eq(0)
    end
  end

  describe "#should_evaluate?" do
    it "returns true when no previous evaluation exists" do
      expect(evaluator.should_evaluate?).to be true
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
  end

  describe "#evaluate_all_pairs" do
    let!(:trading_pair) { create(:trading_pair, enabled: true) }
    let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
    let(:mock_signal) { {side: "long", price: 50_000, confidence: 80, sl: 49_000, tp: 52_000, quantity: 1} }

    before do
      allow(evaluator).to receive(:should_evaluate?).and_return(true)
      allow(evaluator.strategies["MultiTimeframeSignal"]).to receive(:signal).and_return(mock_signal)
      allow(evaluator).to receive(:has_sufficient_data?).and_return(true)
      allow(evaluator).to receive(:valid_signal?).and_return(true)
      allow(evaluator).to receive(:should_create_signal?).and_return(true)
      allow(SignalAlert).to receive(:create_entry_signal!)
    end

    context "when no enabled trading pairs exist" do
      before do
        TradingPair.update_all(enabled: false)
      end

      it "logs warning and returns early" do
        evaluator.evaluate_all_pairs

        expect(logger).to have_received(:warn).with(/No enabled trading pairs found/)
        expect(logger).to have_received(:info).with(/To sync products/)
      end
    end

    context "when enabled trading pairs exist" do
      it "evaluates all enabled pairs" do
        evaluator.evaluate_all_pairs

        expect(logger).to have_received(:info).with(/Evaluating \d+ enabled trading pairs/)
        expect(evaluator).to have_received(:should_evaluate?)
      end

      it "calls evaluate_pair for each enabled pair" do
        allow(evaluator).to receive(:evaluate_pair)

        evaluator.evaluate_all_pairs

        expect(evaluator).to have_received(:evaluate_pair).with(trading_pair)
      end

      it "updates last evaluation timestamp" do
        evaluator.evaluate_all_pairs

        expect(evaluator.last_evaluation[:all]).to be_within(1.second).of(Time.current.utc)
      end
    end

    context "when evaluation is not needed" do
      before do
        allow(evaluator).to receive(:should_evaluate?).and_return(false)
        allow(evaluator).to receive(:evaluate_pair)
      end

      it "returns early without evaluating" do
        evaluator.evaluate_all_pairs

        expect(evaluator).not_to have_received(:evaluate_pair)
      end
    end
  end

  describe "#evaluate_pair" do
    let(:trading_pair) { create(:trading_pair, product_id: "BTC-29DEC24-CDE") }
    let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
    let(:mock_signal) { {side: "long", price: 50_000, confidence: 80, sl: 49_000, tp: 52_000, quantity: 1} }

    before do
      allow(evaluator.strategies["MultiTimeframeSignal"]).to receive(:signal).and_return(mock_signal)
      allow(evaluator).to receive(:has_sufficient_data?).and_return(true)
      allow(evaluator).to receive(:valid_signal?).and_return(true)
      allow(evaluator).to receive(:should_create_signal?).and_return(true)
      allow(SignalAlert).to receive(:create_entry_signal!)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "10000").and_return("15000")
    end

    it "resolves symbol from trading pair" do
      allow(evaluator).to receive(:resolve_symbol).and_return("BTC-29DEC24-CDE")

      evaluator.evaluate_pair(trading_pair)

      expect(evaluator).to have_received(:resolve_symbol).with("BTC-29DEC24-CDE")
    end

    it "uses configured equity amount" do
      evaluator.evaluate_pair(trading_pair)

      expect(ENV).to have_received(:fetch).with("SIGNAL_EQUITY_USD", "10000")
    end

    it "evaluates each strategy for the symbol" do
      evaluator.evaluate_pair(trading_pair)

      expect(evaluator.strategies["MultiTimeframeSignal"]).to have_received(:signal).with(
        symbol: anything,
        equity_usd: 15_000.0
      )
    end

    it "creates signal alert when strategy returns valid signal" do
      evaluator.evaluate_pair(trading_pair)

      expect(SignalAlert).to have_received(:create_entry_signal!).with(
        symbol: anything,
        side: "long",
        strategy_name: "MultiTimeframeSignal",
        confidence: 80,
        entry_price: 50_000,
        stop_loss: 49_000,
        take_profit: 52_000,
        quantity: 1,
        timeframe: anything,
        metadata: anything,
        strategy_data: anything
      )
    end

    it "logs successful signal creation" do
      evaluator.evaluate_pair(trading_pair)

      expect(logger).to have_received(:info).with(/Created signal alert/)
    end

    it "updates last evaluation timestamp for symbol" do
      evaluator.evaluate_pair(trading_pair)

      # The symbol should be resolved from the trading pair
      resolved_symbol = evaluator.send(:resolve_symbol, "BTC-29DEC24-CDE")
      expect(evaluator.last_evaluation[resolved_symbol]).to be_within(1.second).of(Time.current.utc)
    end

    context "when strategy raises error" do
      before do
        allow(evaluator.strategies["MultiTimeframeSignal"]).to receive(:signal).and_raise(StandardError.new("Strategy error"))
      end

      it "logs the error and continues" do
        expect { evaluator.evaluate_pair(trading_pair) }.not_to raise_error

        expect(logger).to have_received(:error).with(/Error evaluating MultiTimeframeSignal/)
        expect(logger).to have_received(:error).with(/Strategy error/)
      end
    end
  end

  describe "#has_sufficient_data?" do
    let(:symbol) { "BTC-29DEC24-CDE" }

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
        # Missing 1m data
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

  describe "#should_create_signal?" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-29DEC24-CDE" }
    let(:signal) { {side: "long", confidence: 80} }

    before do
      allow(evaluator).to receive(:signal_rate_limited?).and_return(false)
      allow(evaluator).to receive(:duplicate_signal?).and_return(false)
    end

    it "returns true when no rate limiting or duplicates" do
      expect(evaluator.send(:should_create_signal?, strategy_name, symbol, signal)).to be true
    end

    it "checks for rate limiting" do
      evaluator.send(:should_create_signal?, strategy_name, symbol, signal)

      expect(evaluator).to have_received(:signal_rate_limited?).with(strategy_name, symbol)
    end

    it "checks for duplicate signals" do
      evaluator.send(:should_create_signal?, strategy_name, symbol, signal)

      expect(evaluator).to have_received(:duplicate_signal?).with(strategy_name, symbol, signal)
    end

    it "returns false when rate limited" do
      allow(evaluator).to receive(:signal_rate_limited?).and_return(true)

      expect(evaluator.send(:should_create_signal?, strategy_name, symbol, signal)).to be false
    end

    it "returns false when duplicate signal exists" do
      allow(evaluator).to receive(:duplicate_signal?).and_return(true)

      expect(evaluator.send(:should_create_signal?, strategy_name, symbol, signal)).to be false
    end
  end

  describe "#signal_rate_limited?" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-29DEC24-CDE" }

    before do
      evaluator.instance_variable_set(:@max_signals_per_hour, 5)
    end

    context "when under rate limit" do
      before do
        create_list(:signal_alert, 3, strategy_name: strategy_name, symbol: symbol, alert_timestamp: 30.minutes.ago)
      end

      it "returns false" do
        expect(evaluator.send(:signal_rate_limited?, strategy_name, symbol)).to be false
      end
    end

    context "when at rate limit" do
      before do
        create_list(:signal_alert, 5, strategy_name: strategy_name, symbol: symbol, alert_timestamp: 30.minutes.ago)
      end

      it "returns true and logs rate limiting" do
        expect(evaluator.send(:signal_rate_limited?, strategy_name, symbol)).to be true

        expect(logger).to have_received(:debug).with(/Rate limited/)
      end
    end
  end

  describe "#duplicate_signal?" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-29DEC24-CDE" }
    let(:signal) { {side: "long", confidence: 80} }

    before do
      evaluator.instance_variable_set(:@deduplication_window, 10.minutes)
    end

    context "when no duplicate exists" do
      it "returns false" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be false
      end
    end

    context "when duplicate exists within window" do
      before do
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "long",
          signal_type: "entry",
          alert_status: "active",
          confidence: 80,
          alert_timestamp: 5.minutes.ago)
      end

      it "returns true" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be true
      end
    end

    context "when similar confidence signal exists" do
      before do
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "long",
          signal_type: "entry",
          alert_status: "active",
          confidence: 75, # Within 10% of 80
          alert_timestamp: 5.minutes.ago)
      end

      it "returns true" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be true
      end
    end

    context "when duplicate is outside window" do
      before do
        create(:signal_alert,
          strategy_name: strategy_name,
          symbol: symbol,
          side: "long",
          signal_type: "entry",
          alert_status: "active",
          confidence: 80,
          alert_timestamp: 15.minutes.ago) # Outside 10 minute window
      end

      it "returns false" do
        expect(evaluator.send(:duplicate_signal?, strategy_name, symbol, signal)).to be false
      end
    end
  end

  describe "#create_signal_alert" do
    let(:strategy_name) { "MultiTimeframeSignal" }
    let(:symbol) { "BTC-29DEC24-CDE" }
    let(:signal) do
      {side: "long", price: 50_000, confidence: 80, sl: 49_000, tp: 52_000, quantity: 1, timeframe: "15m"}
    end

    before do
      allow(evaluator).to receive(:should_create_signal?).and_return(true)
      allow(evaluator).to receive(:detect_timeframe).and_return("15m")
      allow(evaluator).to receive(:build_metadata).and_return({})
      allow(SignalAlert).to receive(:create_entry_signal!).and_return(build(:signal_alert))
    end

    it "creates signal alert with correct parameters" do
      evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

      expect(SignalAlert).to have_received(:create_entry_signal!).with(
        symbol: symbol,
        side: "long",
        strategy_name: strategy_name,
        confidence: 80,
        entry_price: 50_000,
        stop_loss: 49_000,
        take_profit: 52_000,
        quantity: 1,
        timeframe: "15m",
        metadata: {},
        strategy_data: hash_including(timeframe: "15m")
      )
    end

    it "logs successful signal creation" do
      evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

      expect(logger).to have_received(:info).with(/Created signal alert/)
    end

    context "when SignalBroadcaster is defined" do
      before do
        stub_const("SignalBroadcaster", double)
        allow(SignalBroadcaster).to receive(:broadcast)
      end

      it "broadcasts the signal" do
        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

        expect(SignalBroadcaster).to have_received(:broadcast).with(signal)
      end
    end

    context "when signal creation fails" do
      before do
        allow(SignalAlert).to receive(:create_entry_signal!).and_raise(StandardError.new("DB error"))
      end

      it "logs the error" do
        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

        expect(logger).to have_received(:error).with(/Failed to create signal alert/)
      end
    end

    context "when broadcasting fails" do
      before do
        stub_const("SignalBroadcaster", double)
        allow(SignalBroadcaster).to receive(:broadcast).and_raise(StandardError.new("Broadcast error"))
      end

      it "logs the broadcast error" do
        evaluator.send(:create_signal_alert, strategy_name, symbol, signal)

        expect(logger).to have_received(:error).with(/Failed to broadcast signal/)
      end
    end
  end

  describe "#analyze_market_conditions" do
    let(:symbol) { "BTC-29DEC24-CDE" }
    let(:signal) { {symbol: symbol} }

    context "when candles exist for all timeframes" do
      before do
        %w[1h 15m 5m 1m].each do |timeframe|
          20.times do |i|
            create(:candle,
              symbol: symbol,
              timeframe: timeframe,
              close: 50_000,
              timestamp: i.hours.ago)
          end
        end
      end

      it "calculates volatility for each timeframe" do
        conditions = evaluator.send(:analyze_market_conditions, signal)

        expect(conditions).to have_key("1h_volatility")
        expect(conditions).to have_key("15m_volatility")
        expect(conditions).to have_key("5m_volatility")
        expect(conditions).to have_key("1m_volatility")
      end

      it "returns numeric volatility values" do
        conditions = evaluator.send(:analyze_market_conditions, signal)

        conditions.each_value do |volatility|
          expect(volatility).to be_a(Float)
          expect(volatility).to be >= 0
        end
      end
    end

    context "when insufficient candles exist" do
      before do
        create_list(:candle, 5, symbol: symbol, timeframe: "1h", close: 50_000)
      end

      it "skips timeframes with insufficient data" do
        conditions = evaluator.send(:analyze_market_conditions, signal)

        expect(conditions).not_to have_key("1h_volatility")
      end
    end
  end

  describe "#calculate_risk_metrics" do
    context "when signal has required data" do
      let(:signal) { {price: 50_000, sl: 49_000, tp: 52_000, quantity: 2} }

      it "calculates risk per unit" do
        metrics = evaluator.send(:calculate_risk_metrics, signal)

        expect(metrics[:risk_per_unit]).to eq(1_000.0)
      end

      it "calculates risk-reward ratio" do
        metrics = evaluator.send(:calculate_risk_metrics, signal)

        expect(metrics[:risk_reward_ratio]).to eq(2.0)
      end

      it "calculates position size percentage" do
        metrics = evaluator.send(:calculate_risk_metrics, signal)

        expect(metrics[:position_size_pct]).to eq(2.0) # 2 * 100 / 100
      end
    end

    context "when required data is missing" do
      it "returns empty hash" do
        metrics = evaluator.send(:calculate_risk_metrics, {})

        expect(metrics).to eq({})
      end

      it "returns empty hash when stop loss is missing" do
        signal = {price: 50_000, tp: 52_000}
        metrics = evaluator.send(:calculate_risk_metrics, signal)

        expect(metrics).to eq({})
      end
    end
  end

  describe "#build_metadata" do
    let(:signal) { {side: "long", price: 50_000} }

    before do
      allow(evaluator).to receive(:analyze_market_conditions).and_return({"1h_volatility" => 0.02})
      allow(evaluator).to receive(:calculate_risk_metrics).and_return({risk_per_unit: 1000.0})
    end

    it "includes evaluation timestamp" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata[:evaluation_timestamp]).to be_a(String)
    end

    it "includes strategy version" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata[:strategy_version]).to eq("1.0")
    end

    it "includes market conditions" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata[:market_conditions]).to eq({"1h_volatility" => 0.02})
    end

    it "includes risk metrics" do
      metadata = evaluator.send(:build_metadata, signal)

      expect(metadata[:risk_metrics]).to eq({risk_per_unit: 1000.0})
    end
  end

  describe "#resolve_symbol_from_signal" do
    it "returns symbol from signal" do
      signal = {symbol: "BTC-29DEC24-CDE"}

      result = evaluator.send(:resolve_symbol_from_signal, signal)

      expect(result).to eq("BTC-29DEC24-CDE")
    end

    it "returns symbol from strategy_data" do
      signal = {strategy_data: {symbol: "ETH-29DEC24-CDE"}}

      result = evaluator.send(:resolve_symbol_from_signal, signal)

      expect(result).to eq("ETH-29DEC24-CDE")
    end

    it "returns nil when no symbol found" do
      signal = {}

      result = evaluator.send(:resolve_symbol_from_signal, signal)

      expect(result).to be_nil
    end
  end
end
