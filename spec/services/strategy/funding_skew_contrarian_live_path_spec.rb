# frozen_string_literal: true

require "rails_helper"

# Live-path compatibility (#568 "to paper-trade it"): the live evaluators call
# signal(symbol:, equity_usd:) with NO as_of and expect candle reads through
# the live tables. The backtest path always passed as_of and injected a
# preloaded source — this spec proves the strategy stands on the live
# defaults: wall-clock as_of, CandleSource::Database.
RSpec.describe Strategy::FundingSkewContrarian, "live path", type: :service do
  let(:perp) { "BIP-LIVE-TEST" }
  let(:spot) { "SPOT-LIVE-TEST" }
  let(:now) { Time.zone.parse("2026-07-28T12:00:30Z") }

  def seed_minute(symbol, timestamp, close)
    Candle.create!(symbol: symbol, timeframe: "1m", timestamp: timestamp,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  # window 3 needs 4 complete joint hour buckets at/before now. Seed one 1m bar
  # per hour; the last complete bucket carries an extreme premium.
  def seed_live_history(premiums)
    start = now - premiums.size.hours
    premiums.each_with_index do |p, i|
      seed_minute(perp, start + i.hours, 100.0 * (1.0 + p))
      seed_minute(spot, start + i.hours, 100.0)
    end
  end

  let(:strategy) do
    described_class.new(window: 3, entry_z: 2.0, exit_z: 0.5, stop: 0.01, spot_symbol: spot)
  end

  around { |example| travel_to(now) { example.run } }

  it "produces a signal from live candle tables without an as_of" do
    seed_live_history([0.001, -0.001, 0.001, 0.02])

    sig = strategy.signal(symbol: perp, equity_usd: 10_000.0)

    expect(sig).not_to be_nil
    expect(sig[:side]).to eq(:short)
    expect(sig[:price]).to be_within(1e-9).of(102.0)
    expect(sig[:quantity]).to eq(1)
  end

  it "returns nil with a rejection code when live history is too short" do
    seed_live_history([0.001, 0.02])

    expect(strategy.signal(symbol: perp, equity_usd: 10_000.0)).to be_nil
    expect(strategy.last_rejection).to eq(:insufficient_premium_history)
  end

  it "reads through the default Database candle source when none is injected" do
    expect(strategy.candle_source).to be_a(Signals::CandleSource::Database)
  end

  # The realtime evaluator gates evaluation on recent candles per timeframe.
  # This strategy consumes ONLY 1m bars — requiring 1h/15m/5m data would
  # silently starve it whenever those syncs lag.
  it "declares that it only needs 1m candles" do
    expect(strategy.required_timeframes).to eq(["1m"])
  end
end
