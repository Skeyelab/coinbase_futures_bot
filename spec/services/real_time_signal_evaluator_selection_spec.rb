# frozen_string_literal: true

require "rails_helper"

# Declarative strategy selection in the realtime loop (#303/#568): a symbol
# with an enabled entry in config/strategy_selection.yml is evaluated with the
# configured strategy — resolved through Trading::StrategyFactory.for_symbol,
# the same site the execution jobs use — while every other symbol keeps
# today's MultiTimeframeSignal behavior byte for byte.
RSpec.describe RealTimeSignalEvaluator, "declarative selection", type: :service do
  let(:evaluator) { described_class.new(logger: Logger.new(IO::NULL)) }
  let(:perp) { "BIP-RTSE-CDE" }
  let(:spot) { "SPOT-RTSE-CDE" }
  let!(:contract) { create(:contract, enabled: true, product_id: perp) }
  let(:now) { Time.zone.parse("2026-07-28T12:00:30Z") }

  def stub_selection(symbols)
    allow(Trading::StrategySelection).to receive(:default)
      .and_return(Trading::StrategySelection.new({"symbols" => symbols}))
  end

  def seed_minute(symbol, timestamp, close)
    Candle.create!(symbol: symbol, timeframe: "1m", timestamp: timestamp,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  def seed_skewed_history(premiums = [0.001, -0.001, 0.001, 0.02])
    start = now - premiums.size.hours
    premiums.each_with_index do |p, i|
      seed_minute(perp, start + i.hours, 100.0 * (1.0 + p))
      seed_minute(spot, start + i.hours, 100.0)
    end
  end

  around { |example| travel_to(now) { example.run } }

  context "with an enabled funding-skew entry for the symbol" do
    before do
      stub_selection(perp => {
        "strategy" => "FundingSkewContrarian",
        "min_confidence" => 0,
        "params" => {"entry_z" => 2.0, "exit_z" => 0.5, "window" => 3,
                     "stop" => 0.01, "spot_symbol" => spot}
      })
      allow(Trading::SignalEquity).to receive(:usd).and_return(10_000.0)
      seed_skewed_history
    end

    it "creates a SignalAlert under the configured strategy's name" do
      stats = evaluator.evaluate_pair(contract)

      expect(stats[:signals_created]).to eq(1)
      alert = SignalAlert.last
      expect(alert.strategy_name).to eq("FundingSkewContrarian")
      expect(alert.symbol).to eq(perp)
      expect(alert.side).to eq("short")
    end

    # entry_z ~2 maps to confidence ~20 on this strategy's z*10 scale; the
    # profile's MTS-calibrated threshold (default 60) must not re-filter a
    # strategy whose entry_z IS the filter.
    it "honors the entry's min_confidence override instead of the profile threshold" do
      # extreme-but-small z: premiums make z just above 2 -> confidence ~20-30
      Candle.where(symbol: perp).delete_all
      Candle.where(symbol: spot).delete_all
      seed_skewed_history([0.001, -0.001, 0.001, 0.0028])

      stats = evaluator.evaluate_pair(contract)

      expect(stats[:signals_created]).to eq(1)
      expect(SignalAlert.last.confidence.to_f).to be < 60
    end

    # FundingSkewContrarian consumes only 1m bars. No 1h/15m/5m candles are
    # seeded in these examples — signal creation above already proves the
    # sufficiency gate follows the strategy's own declared timeframes.
    it "does not require 1h/15m/5m candles for a 1m-only strategy" do
      expect(Candle.where(symbol: perp).where.not(timeframe: "1m")).to be_empty
      expect(evaluator.evaluate_pair(contract)[:signals_created]).to eq(1)
    end
  end

  context "without an enabled entry" do
    it "evaluates with the default MultiTimeframeSignal, as before" do
      stub_selection({})
      mts = evaluator.strategies["MultiTimeframeSignal"]
      allow(mts).to receive(:signal).and_return(nil)
      # 1m-only seed is NOT sufficient for the default strategy's gate; give
      # it recent candles on all four timeframes so the strategy is consulted.
      %w[1h 15m 5m 1m].each do |tf|
        Candle.create!(symbol: perp, timeframe: tf, timestamp: now - 10.minutes,
          open: 100, high: 100, low: 100, close: 100, volume: 1)
      end

      evaluator.evaluate_pair(contract)

      expect(mts).to have_received(:signal).with(symbol: perp, equity_usd: kind_of(Float))
    end

    it "keeps the disabled shipped BIP entry on the default strategy" do
      stub_selection("BIP-RTSE-CDE" => {"strategy" => "FundingSkewContrarian", "enabled" => false})
      mts = evaluator.strategies["MultiTimeframeSignal"]
      allow(mts).to receive(:signal).and_return(nil)
      %w[1h 15m 5m 1m].each do |tf|
        Candle.create!(symbol: perp, timeframe: tf, timestamp: now - 10.minutes,
          open: 100, high: 100, low: 100, close: 100, volume: 1)
      end

      evaluator.evaluate_pair(contract)

      expect(mts).to have_received(:signal)
    end
  end
end
