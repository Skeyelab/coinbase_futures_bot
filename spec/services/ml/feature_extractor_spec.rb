# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::FeatureExtractor do
  let(:symbol) { "BIP-20DEC30-CDE" }
  # Tiny windows so fixtures stay hand-checkable; production defaults are
  # pinned to the live strategy in a separate example below.
  let(:config) do
    {
      window_1h: 3, ema_1h_short: 2, ema_1h_long: 3,
      window_15m: 3, ema_15m: 2,
      window_5m: 4, ema_5m: 2,
      volume_window: 3, momentum_window: 4
    }
  end
  let(:extractor) { described_class.new(symbol: symbol, config: config) }
  let(:t) { Time.utc(2026, 1, 1, 12, 0, 0) } # the bar under test

  def insert_candles(timeframe, rows)
    now = Time.current
    Candle.insert_all(rows.map do |ts, close, volume|
      {symbol: symbol, timeframe: timeframe, timestamp: ts,
       open: close, high: close, low: close, close: close, volume: volume || 10.0,
       created_at: now, updated_at: now}
    end)
  end

  # 5m bars 11:45..12:00 -> closes 100, 101, 102, 103; volumes 10, 10, 20, 30.
  def base_5m
    insert_candles("5m", [
      [t - 900, 100.0, 10.0], [t - 600, 101.0, 10.0],
      [t - 300, 102.0, 20.0], [t, 103.0, 30.0]
    ])
  end

  # 15m bars 11:15, 11:30, 11:45 (all closed by 12:05) -> 200, 202, 204.
  def base_15m
    insert_candles("15m", [[t - 2700, 200.0], [t - 1800, 202.0], [t - 900, 204.0]])
  end

  # 1h bars 09:00, 10:00, 11:00 (all closed by 12:05) -> 300, 303, 309.
  def base_1h
    insert_candles("1h", [[t - 3.hours, 300.0], [t - 2.hours, 303.0], [t - 1.hour, 309.0]])
  end

  describe "#features_for_range" do
    before do
      base_5m
      base_15m
      base_1h
    end

    it "computes the six confidence-score features with the live EMA math (hand-checkable)" do
      features = extractor.features_for_range(from: t, to: t).fetch(t)

      ema1h_s = Signals::Indicators.ema([300.0, 303.0, 309.0], 2)
      ema1h_l = Signals::Indicators.ema([300.0, 303.0, 309.0], 3)
      ema15 = Signals::Indicators.ema([200.0, 202.0, 204.0], 2)
      ema5 = Signals::Indicators.ema([100.0, 101.0, 102.0, 103.0], 2)

      expect(features["trend_1h"]).to be_within(1e-12).of((ema1h_s - ema1h_l) / ema1h_l)
      expect(features["align_15m"]).to be_within(1e-12).of((103.0 - ema15) / ema15)
      expect(features["align_5m"]).to be_within(1e-12).of((103.0 - ema5) / ema5)
      # roc over the momentum window: (103 - 100) / 100, exactly live's closes[-4] rule
      expect(features["momentum_5m"]).to be_within(1e-12).of(0.03)
      # volume window [10, 20, 30]: avg 20, current 30 -> ratio 1.5; rising -> trend 1.0
      expect(features["volume_ratio"]).to eq(1.5)
      expect(features["volume_trend"]).to eq(1.0)
    end

    it "never looks ahead: candles after the bar cannot change its features" do
      before_features = extractor.features_for_range(from: t, to: t).fetch(t)

      insert_candles("5m", [[t + 300, 999.0, 999.0]])
      insert_candles("15m", [[t, 999.0]])   # closes 12:15 — not closed at 12:05
      insert_candles("1h", [[t, 999.0]])    # closes 13:00 — not closed at 12:05

      after_features = extractor.features_for_range(from: t, to: t).fetch(t)
      expect(after_features).to eq(before_features)
    end

    it "only uses higher-timeframe bars that have CLOSED by the 5m bar's close" do
      # A 15m bar at 11:50 does not exist on a real grid, but one at 11:45
      # closes at 12:00 <= 12:05 and must be the last usable window element —
      # replacing ITS close moves align_15m, proving it is in the window.
      baseline = extractor.features_for_range(from: t, to: t).fetch(t)

      Candle.find_by(symbol: symbol, timeframe: "15m", timestamp: t - 900).update!(close: 210.0)
      moved = extractor.features_for_range(from: t, to: t).fetch(t)

      expect(moved["align_15m"]).not_to eq(baseline["align_15m"])
    end

    it "caps the volume ratio at 3x average, exactly like the live scorer" do
      # A 4-bar window so a spike can exceed 3x the (spike-inclusive) average:
      # [10, 10, 20, 500] -> avg 135, raw ratio 3.7 -> capped at 3.0.
      Candle.find_by(symbol: symbol, timeframe: "5m", timestamp: t).update!(volume: 500.0)
      capped = described_class.new(symbol: symbol, config: config.merge(volume_window: 4))

      features = capped.features_for_range(from: t, to: t).fetch(t)
      expect(features["volume_ratio"]).to eq(3.0)
    end

    it "marks falling volume with the live 0.5 trend factor" do
      Candle.find_by(symbol: symbol, timeframe: "5m", timestamp: t).update!(volume: 5.0)

      features = extractor.features_for_range(from: t, to: t).fetch(t)
      expect(features["volume_trend"]).to eq(0.5)
    end

    it "skips bars with insufficient history instead of guessing" do
      # 11:55 has only 3 prior 5m bars (needs window_5m = 4)... and the range
      # end at 12:00 has full history, so exactly one bar comes back.
      features = extractor.features_for_range(from: t - 300, to: t)

      expect(features.keys).to eq([t])
    end

    it "skips bars when the higher-timeframe window is short" do
      Candle.find_by(symbol: symbol, timeframe: "1h", timestamp: t - 3.hours).destroy!

      expect(extractor.features_for_range(from: t, to: t)).to be_empty
    end

    it "labels every returned row with all declared feature names" do
      features = extractor.features_for_range(from: t, to: t).fetch(t)
      expect(features.keys).to match_array(described_class::FEATURE_NAMES)
    end
  end

  describe "DEFAULTS" do
    it "pins window sizes and EMA periods to the live strategy's configuration" do
      live = Strategy::MultiTimeframeSignal::DEFAULTS

      expect(described_class::DEFAULTS).to include(
        ema_1h_short: live[:ema_1h_short],
        ema_1h_long: live[:ema_1h_long],
        ema_15m: live[:ema_15m],
        ema_5m: live[:ema_5m],
        window_1h: live[:min_1h_candles],
        window_15m: live[:min_15m_candles],
        window_5m: live[:min_5m_candles],
        volume_window: 10,
        momentum_window: 8
      )
    end
  end
end
