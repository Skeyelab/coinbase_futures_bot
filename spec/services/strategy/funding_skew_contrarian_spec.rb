# frozen_string_literal: true

require "rails_helper"

# Issue #568 rank-3 candidate, driven by the #569 basis proxy: when the hourly
# perp-vs-spot premium z-score is extreme, fade the crowded side — SHORT when
# longs are paying (z > entry_z), LONG when shorts are (z < -entry_z). The tp
# encodes the z-reversion exit as a price (premium back to exit_z sigmas,
# spot held constant); the sl is a hard fractional stop. Taker entries: this
# candidate pays fees, which is part of its test.
RSpec.describe Strategy::FundingSkewContrarian, type: :service do
  let(:perp) { "BIP-SKEW-TEST" }
  let(:spot) { "SPOT-SKEW-TEST" }
  let(:t0) { Time.parse("2026-03-01T00:00:00Z") }

  def seed_minute(symbol, timestamp, close)
    Candle.create!(symbol: symbol, timeframe: "1m", timestamp: timestamp,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  # One 1m candle per hour is enough: hour buckets close on the clock, and the
  # proxy takes the last stored close per bucket.
  def seed_premiums(premiums, from: t0)
    premiums.each_with_index do |p, i|
      seed_minute(perp, from + i.hours, 100.0 * (1.0 + p))
      seed_minute(spot, from + i.hours, 100.0)
    end
  end

  def strategy(**config)
    described_class.new({window: 3, entry_z: 2.0, exit_z: 0.5, stop: 0.01,
                         spot_symbol: spot}.merge(config))
  end

  # Trailing stats for premiums [0.001, -0.001, 0.001] (window 3).
  let(:trailing) { [0.001, -0.001, 0.001] }
  let(:mean) { trailing.sum / 3.0 }
  let(:sd) { Math.sqrt(trailing.sum { |p| (p - mean)**2 } / 2.0) }

  describe "crowded longs (z > entry_z)" do
    before { seed_premiums(trailing + [0.02]) }

    let(:sig) { strategy.signal(symbol: perp, as_of: t0 + 4.hours) }
    let(:z) { (0.02 - mean) / sd }

    it "fades the crowd with a SHORT at the latest perp close" do
      expect(sig[:side]).to eq(:short)
      expect(sig[:price]).to be_within(1e-9).of(102.0)
    end

    it "targets the price where the premium has reverted to exit_z sigmas" do
      expect(sig[:tp]).to be_within(1e-9).of(102.0 * (1.0 - (z - 0.5) * sd))
    end

    it "stops a hard fraction beyond entry" do
      expect(sig[:sl]).to be_within(1e-9).of(102.0 * 1.01)
    end

    it "reports a bounded confidence" do
      expect(sig[:confidence]).to be_between(0.0, 100.0)
    end
  end

  describe "crowded shorts (z < -entry_z)" do
    before { seed_premiums(trailing + [-0.02]) }

    let(:sig) { strategy.signal(symbol: perp, as_of: t0 + 4.hours) }
    let(:z) { (-0.02 - mean) / sd }

    it "goes LONG with mirrored tp/sl" do
      expect(sig[:side]).to eq(:long)
      expect(sig[:price]).to be_within(1e-9).of(98.0)
      expect(sig[:tp]).to be_within(1e-9).of(98.0 * (1.0 + (z.abs - 0.5) * sd))
      expect(sig[:sl]).to be_within(1e-9).of(98.0 * 0.99)
    end
  end

  describe "flat in noise" do
    it "returns nil with :skew_inside_band when |z| is below entry_z" do
      seed_premiums(trailing + [0.0012]) # z ~ 0.75

      s = strategy
      expect(s.signal(symbol: perp, as_of: t0 + 4.hours)).to be_nil
      expect(s.last_rejection).to eq(:skew_inside_band)
    end
  end

  describe "rejections" do
    it "returns nil with :insufficient_premium_history when the window cannot fill" do
      seed_premiums([0.001, -0.001])

      s = strategy
      expect(s.signal(symbol: perp, as_of: t0 + 2.hours)).to be_nil
      expect(s.last_rejection).to eq(:insufficient_premium_history)
    end

    it "returns nil when the trailing premium has zero variance (z undefined)" do
      seed_premiums([0.001, 0.001, 0.001, 0.02])

      s = strategy
      expect(s.signal(symbol: perp, as_of: t0 + 4.hours)).to be_nil
      expect(s.last_rejection).to eq(:insufficient_premium_history)
    end

    it "returns nil when contracts is zero" do
      seed_premiums(trailing + [0.02])

      expect(strategy(contracts: 0).signal(symbol: perp, as_of: t0 + 4.hours)).to be_nil
    end
  end

  describe "as_of discipline" do
    it "ignores hours after as_of: the signal at T is the same with or without the future" do
      seed_premiums(trailing + [0.02])

      before_future = strategy.signal(symbol: perp, as_of: t0 + 4.hours)
      seed_premiums([0.5], from: t0 + 4.hours) # wild future hour
      after_future = strategy(window: 3).signal(symbol: perp, as_of: t0 + 4.hours)

      expect(after_future).to eq(before_future)
    end
  end

  describe "sizing" do
    it "sizes in whole contracts from config" do
      seed_premiums(trailing + [0.02])

      expect(strategy(contracts: 2).signal(symbol: perp, as_of: t0 + 4.hours)[:quantity]).to eq(2)
    end
  end

  describe "backtest support surface" do
    it "declares its 1m warm-up for the preloading candle source" do
      expect(strategy(window: 3).warmup_candles).to eq({one_minute: 5 * 60})
    end

    it "defaults the candle source to the database (live path)" do
      expect(described_class.new.candle_source).to be_a(Signals::CandleSource::Database)
    end
  end
end
