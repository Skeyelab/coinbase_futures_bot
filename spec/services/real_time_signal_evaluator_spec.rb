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
end
