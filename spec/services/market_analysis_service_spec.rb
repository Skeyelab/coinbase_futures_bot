# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketAnalysisService do
  subject(:service) { described_class.new(symbol: "BIT-29AUG25-CDE") }

  describe "TREND_SCORES" do
    it "maps trend directions to scores" do
      expect(MarketAnalysisService::TREND_SCORES["strong_uptrend"]).to eq(3)
      expect(MarketAnalysisService::TREND_SCORES["uptrend"]).to eq(2)
      expect(MarketAnalysisService::TREND_SCORES["strong_downtrend"]).to eq(-3)
      expect(MarketAnalysisService::TREND_SCORES["downtrend"]).to eq(-2)
    end
  end

  describe "#score_trend" do
    it "returns correct score for known trends" do
      expect(service.send(:score_trend, "strong_uptrend")).to eq(3)
      expect(service.send(:score_trend, "uptrend")).to eq(2)
      expect(service.send(:score_trend, "strong_downtrend")).to eq(-3)
      expect(service.send(:score_trend, "downtrend")).to eq(-2)
    end

    it "returns 0 for unknown/neutral trend" do
      expect(service.send(:score_trend, "sideways")).to eq(0)
      expect(service.send(:score_trend, nil)).to eq(0)
    end
  end

  describe "#score_signals" do
    it "returns correct score for signal quality" do
      expect(service.send(:score_signals, "excellent")).to eq(2)
      expect(service.send(:score_signals, "good")).to eq(1)
      expect(service.send(:score_signals, "fair")).to eq(0)
      expect(service.send(:score_signals, "poor")).to eq(-1)
      expect(service.send(:score_signals, "unknown")).to eq(-1)
    end
  end

  describe "#score_risk" do
    it "returns penalty scores for risk levels" do
      expect(service.send(:score_risk, "high")).to eq(3)
      expect(service.send(:score_risk, "medium")).to eq(1)
      expect(service.send(:score_risk, "low")).to eq(0)
    end
  end

  describe "#rsi_interpretation" do
    it "classifies RSI into zones" do
      expect(service.send(:rsi_interpretation, 20)).to eq("Oversold")
      expect(service.send(:rsi_interpretation, 40)).to eq("Bearish")
      expect(service.send(:rsi_interpretation, 60)).to eq("Bullish")
      expect(service.send(:rsi_interpretation, 80)).to eq("Overbought")
    end

    it "returns Unknown for out-of-range values" do
      expect(service.send(:rsi_interpretation, 110)).to eq("Unknown")
    end
  end

  describe "#classify_sentiment_strength" do
    it "classifies weak sentiment" do
      expect(service.send(:classify_sentiment_strength, 0.2)).to eq("weak")
      expect(service.send(:classify_sentiment_strength, -0.2)).to eq("weak")
    end

    it "classifies moderate sentiment" do
      expect(service.send(:classify_sentiment_strength, 0.7)).to eq("moderate")
    end

    it "classifies strong sentiment" do
      expect(service.send(:classify_sentiment_strength, 1.5)).to eq("strong")
    end

    it "classifies extreme sentiment" do
      expect(service.send(:classify_sentiment_strength, 3.0)).to eq("extreme")
    end
  end

  describe "#assess_position_risk" do
    it "returns low for empty positions" do
      expect(service.send(:assess_position_risk, [])).to eq("low")
    end

    it "returns low for small exposure" do
      p = instance_double(Position, size: 0.1, entry_price: 5000) # $500
      expect(service.send(:assess_position_risk, [p])).to eq("low")
    end

    it "returns medium for mid-range exposure" do
      p = instance_double(Position, size: 1, entry_price: 10_000) # $10k
      expect(service.send(:assess_position_risk, [p])).to eq("medium")
    end

    it "returns high for large exposure" do
      p = instance_double(Position, size: 5, entry_price: 10_000) # $50k
      expect(service.send(:assess_position_risk, [p])).to eq("high")
    end
  end

  describe "#calculate_position_size" do
    around do |example|
      ClimateControl.modify(SIGNAL_EQUITY_USD: "10000") { example.run }
    end

    it "uses 2% risk for low risk level" do
      size = service.send(:calculate_position_size, 50_000, 49_000, "low")
      expected = (10_000 * 0.02 / 1000).round(2)
      expect(size).to eq(expected)
    end

    it "uses 1.5% risk for medium risk level" do
      size = service.send(:calculate_position_size, 50_000, 49_000, "medium")
      expected = (10_000 * 0.015 / 1000).round(2)
      expect(size).to eq(expected)
    end

    it "uses 1% risk for high risk level" do
      size = service.send(:calculate_position_size, 50_000, 49_000, "high")
      expected = (10_000 * 0.01 / 1000).round(2)
      expect(size).to eq(expected)
    end
  end

  describe "TIMEFRAME_SCOPE" do
    it "covers all supported timeframes" do
      expect(MarketAnalysisService::TIMEFRAME_SCOPE.keys).to contain_exactly("1m", "5m", "15m", "1h")
    end
  end

  describe "#get_recent_candles" do
    it "delegates to the correct candle scope for each timeframe" do
      %w[1m 5m 15m 1h].each do |tf|
        svc = described_class.new(symbol: "BIT-29AUG25-CDE", timeframe: tf)
        scope_name = MarketAnalysisService::TIMEFRAME_SCOPE[tf]
        scope_double = double("scope")
        allow(Candle).to receive(:for_symbol).and_return(scope_double)
        allow(scope_double).to receive(scope_name).and_return(scope_double)
        allow(scope_double).to receive(:order).and_return(scope_double)
        allow(scope_double).to receive(:last).and_return([])

        svc.send(:get_recent_candles)

        expect(scope_double).to have_received(scope_name)
      end
    end

    it "falls back to hourly for unknown timeframes" do
      svc = described_class.new(symbol: "BIT-29AUG25-CDE", timeframe: "unknown")
      scope_double = double("scope")
      allow(Candle).to receive(:for_symbol).and_return(scope_double)
      allow(scope_double).to receive(:hourly).and_return(scope_double)
      allow(scope_double).to receive(:order).and_return(scope_double)
      allow(scope_double).to receive(:last).and_return([])

      svc.send(:get_recent_candles)

      expect(scope_double).to have_received(:hourly)
    end
  end
end
