# frozen_string_literal: true

require "rails_helper"

# Issue #569: the CDE Derivatives API is inaccessible at retail tier, so
# funding HISTORY is proxied by the hourly perp-vs-spot premium computed from
# stored 1m candles (empirically r = 0.77 against 143 hours of real
# funding_rates snapshots). These specs pin the proxy's honesty properties:
# no look-ahead, completed hours only, a z-score window that actually rolls,
# and a cross-validation helper whose correlation math is hand-verifiable.
RSpec.describe Signals::FundingProxy, type: :service do
  let(:perp) { "BIP-PROXY-TEST" }
  let(:spot) { "SPOT-PROXY-TEST" }
  let(:t0) { Time.parse("2026-03-01T10:00:00Z") }

  def seed_minute(symbol, timestamp, close)
    Candle.create!(symbol: symbol, timeframe: "1m", timestamp: timestamp,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  def proxy(window: 3)
    described_class.new(perp_symbol: perp, spot_symbol: spot, window: window)
  end

  describe "#premium_series" do
    it "uses the LAST 1m close of each hour for both legs (hand-verified premium)" do
      seed_minute(perp, t0, 101.0)
      seed_minute(perp, t0 + 30.minutes, 101.5)
      seed_minute(perp, t0 + 59.minutes, 102.0)
      seed_minute(spot, t0 + 59.minutes, 100.0)

      series = proxy.premium_series(as_of: t0 + 1.hour, hours: 5)

      expect(series.size).to eq(1)
      expect(series.first[:hour]).to eq(t0)
      expect(series.first[:premium]).to be_within(1e-12).of(0.02)
      expect(series.first[:perp_close]).to eq(102.0)
      expect(series.first[:spot_close]).to eq(100.0)
    end

    it "excludes the hour still in progress at as_of" do
      seed_minute(perp, t0, 101.0)
      seed_minute(spot, t0, 100.0)

      expect(proxy.premium_series(as_of: t0 + 58.minutes, hours: 5)).to be_empty
    end

    it "never reads candles after as_of (no look-ahead)" do
      seed_minute(perp, t0 + 59.minutes, 102.0)
      seed_minute(spot, t0 + 59.minutes, 100.0)
      # A wild future print that would change everything if leaked.
      seed_minute(perp, t0 + 2.hours, 500.0)
      seed_minute(spot, t0 + 2.hours, 100.0)

      series = proxy.premium_series(as_of: t0 + 1.hour, hours: 5)

      expect(series.size).to eq(1)
      expect(series.first[:premium]).to be_within(1e-12).of(0.02)
    end

    it "skips hours where either leg is missing rather than inventing a premium" do
      seed_minute(perp, t0, 102.0)          # hour 0: perp only
      seed_minute(perp, t0 + 1.hour, 103.0) # hour 1: both
      seed_minute(spot, t0 + 1.hour, 100.0)

      series = proxy.premium_series(as_of: t0 + 2.hours, hours: 5)

      expect(series.map { |row| row[:hour] }).to eq([t0 + 1.hour])
    end

    it "returns at most the requested number of trailing hours" do
      5.times do |i|
        seed_minute(perp, t0 + i.hours, 100.0 + i)
        seed_minute(spot, t0 + i.hours, 100.0)
      end

      series = proxy.premium_series(as_of: t0 + 5.hours, hours: 2)

      expect(series.map { |row| row[:hour] }).to eq([t0 + 3.hours, t0 + 4.hours])
    end
  end

  describe "#z_score" do
    # premiums [0.001, -0.001, 0.001, 0.005] with window 3: the current value
    # 0.005 is judged against the PRIOR three only.
    def seed_premiums(premiums, from: t0)
      premiums.each_with_index do |p, i|
        seed_minute(perp, from + i.hours, 100.0 * (1.0 + p))
        seed_minute(spot, from + i.hours, 100.0)
      end
    end

    it "computes z of the latest premium against the trailing window (hand-verified)" do
      seed_premiums([0.001, -0.001, 0.001, 0.005])

      stats = proxy(window: 3).z_score(as_of: t0 + 4.hours)

      trailing = [0.001, -0.001, 0.001]
      mean = trailing.sum / 3.0
      sd = Math.sqrt(trailing.sum { |p| (p - mean)**2 } / 2.0)
      expect(stats[:premium]).to be_within(1e-9).of(0.005)
      expect(stats[:mean]).to be_within(1e-12).of(mean)
      expect(stats[:stddev]).to be_within(1e-12).of(sd)
      expect(stats[:z]).to be_within(1e-6).of((0.005 - mean) / sd)
      expect(stats[:perp_close]).to be_within(1e-9).of(100.5)
    end

    it "actually rolls: an outlier older than the window has no effect" do
      # Same trailing window as above, preceded by a huge outlier hour.
      seed_premiums([0.5, 0.001, -0.001, 0.001, 0.005])

      stats = proxy(window: 3).z_score(as_of: t0 + 5.hours)

      trailing = [0.001, -0.001, 0.001]
      mean = trailing.sum / 3.0
      sd = Math.sqrt(trailing.sum { |p| (p - mean)**2 } / 2.0)
      expect(stats[:z]).to be_within(1e-6).of((0.005 - mean) / sd)
    end

    it "returns nil when fewer than window + 1 hours are available" do
      seed_premiums([0.001, -0.001, 0.001])

      expect(proxy(window: 3).z_score(as_of: t0 + 3.hours)).to be_nil
    end

    it "returns nil when the trailing window has zero variance" do
      seed_premiums([0.001, 0.001, 0.001, 0.005])

      expect(proxy(window: 3).z_score(as_of: t0 + 4.hours)).to be_nil
    end
  end

  describe "#correlation_with_funding" do
    def seed_premium_hour(hour, premium)
      seed_minute(perp, hour + 59.minutes, 100.0 * (1.0 + premium))
      seed_minute(spot, hour + 59.minutes, 100.0)
    end

    def seed_rate(funding_time, rate)
      FundingRate.create!(product_id: perp, funding_time: funding_time,
        observed_at: funding_time, funding_rate: rate, funding_interval_seconds: 3600)
    end

    it "computes Pearson r between the proxy and stored rates (hand-verified: r = 0.5)" do
      # premiums [1, 2, 3] bps for the hours ending at t0+1h..t0+3h, matched to
      # funding rates [2, 1, 3] observed at those funding_times: r = 0.5.
      seed_premium_hour(t0, 0.0001)
      seed_premium_hour(t0 + 1.hour, 0.0002)
      seed_premium_hour(t0 + 2.hours, 0.0003)
      seed_rate(t0 + 1.hour, 0.0002)
      seed_rate(t0 + 2.hours, 0.0001)
      seed_rate(t0 + 3.hours, 0.0003)

      result = proxy.correlation_with_funding(from: t0, to: t0 + 3.hours)

      expect(result[:n]).to eq(3)
      expect(result[:r]).to be_within(1e-9).of(0.5)
    end

    it "reports r ~ 1.0 when rates track the premium exactly" do
      [0.0001, 0.0005, 0.0003, 0.0009].each_with_index do |p, i|
        seed_premium_hour(t0 + i.hours, p)
        seed_rate(t0 + (i + 1).hours, p / 24.0)
      end

      result = proxy.correlation_with_funding(from: t0, to: t0 + 4.hours)

      expect(result[:n]).to eq(4)
      expect(result[:r]).to be_within(1e-9).of(1.0)
    end

    it "only pairs rates with an hour the proxy actually covers" do
      seed_premium_hour(t0, 0.0001)
      seed_rate(t0 + 1.hour, 0.0002)
      seed_rate(t0 + 10.hours, 0.0003) # no candles for that hour

      result = proxy.correlation_with_funding(from: t0, to: t0 + 10.hours)

      expect(result[:n]).to eq(1)
      expect(result[:r]).to be_nil # one pair cannot correlate
    end

    it "returns n: 0 with a nil r when nothing overlaps" do
      result = proxy.correlation_with_funding(from: t0, to: t0 + 3.hours)

      expect(result).to eq({n: 0, r: nil})
    end
  end
end
