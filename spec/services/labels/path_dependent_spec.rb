# frozen_string_literal: true

require "rails_helper"

RSpec.describe Labels::PathDependent do
  # Hand-constructed 5m series. Entry is always the bar close; the race is
  # walked over the FOLLOWING bars (entry bar's own extremes never count).
  let(:symbol) { "BIP-20DEC30-CDE" }
  let(:t0) { Time.utc(2026, 1, 1, 0, 0, 0) }

  def make_candle(offset_bars, high:, low:, close:, open: close)
    create(:candle, :five_minute, symbol: symbol,
      timestamp: t0 + offset_bars * 300,
      open: open, high: high, low: low, close: close)
  end

  def labels_for(bar_offset)
    PathDependentLabel.where(symbol: symbol, bar_timestamp: t0 + bar_offset * 300)
      .index_by(&:direction)
  end

  describe "#generate" do
    subject(:generator) do
      described_class.new(symbol: symbol, tp_frac: 0.02, sl_frac: 0.012, horizon: 5)
    end

    it "labels a long win when price reaches tp before touching sl" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 101.0, low: 99.9, close: 100.5)  # neither barrier
      make_candle(2, high: 102.1, low: 100.0, close: 102.0) # high >= 102.0 tp

      generator.generate(from: t0, to: t0)

      long = labels_for(0).fetch("long")
      expect(long.label).to eq("win")
      expect(long.resolved_at_bars).to eq(2)
    end

    it "labels a long loss when sl is touched before tp" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 100.9, low: 98.7, close: 99.0) # low <= 98.8 sl
      make_candle(2, high: 102.5, low: 99.0, close: 102.0) # tp later — too late

      generator.generate(from: t0, to: t0)

      long = labels_for(0).fetch("long")
      expect(long.label).to eq("loss")
      expect(long.resolved_at_bars).to eq(1)
    end

    it "labels pessimistically as loss when one bar spans both tp and sl" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 102.5, low: 98.5, close: 100.0) # high >= tp AND low <= sl

      generator.generate(from: t0, to: t0)

      expect(labels_for(0).fetch("long").label).to eq("loss")
      expect(labels_for(0).fetch("short").label).to eq("loss")
    end

    it "labels unresolved when the horizon expires with neither barrier hit" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      (1..6).each { |k| make_candle(k, high: 100.4, low: 99.6, close: 100.0) }

      generator.generate(from: t0, to: t0)

      long = labels_for(0).fetch("long")
      expect(long.label).to eq("unresolved")
      expect(long.resolved_at_bars).to be_nil
    end

    it "labels unresolved on a data gap even when a bar after the gap would win" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 100.9, low: 99.9, close: 100.5)
      # bar 2 missing — gap
      make_candle(3, high: 103.0, low: 100.0, close: 102.5) # would be a win

      generator.generate(from: t0, to: t0)

      expect(labels_for(0).fetch("long").label).to eq("unresolved")
      expect(labels_for(0).fetch("short").label).to eq("unresolved")
    end

    it "labels a short win as the exact mirror: price falls to tp before rising to sl" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 101.1, low: 99.0, close: 99.2)  # short sl 101.2 safe
      make_candle(2, high: 99.5, low: 97.9, close: 98.0)   # low <= 98.0 short tp

      generator.generate(from: t0, to: t0)

      short = labels_for(0).fetch("short")
      expect(short.label).to eq("win")
      expect(short.resolved_at_bars).to eq(2)
      # Same bar takes the long side through its 98.8 stop (97.9 < 98.8).
      expect(labels_for(0).fetch("long").label).to eq("loss")
    end

    it "ignores the entry bar's own extremes — the race starts on the next bar" do
      # Entry bar itself spans the long tp; must not count.
      make_candle(0, high: 103.0, low: 99.5, close: 100.0)
      (1..5).each { |k| make_candle(k, high: 100.4, low: 99.6, close: 100.0) }

      generator.generate(from: t0, to: t0)

      expect(labels_for(0).fetch("long").label).to eq("unresolved")
    end

    it "is idempotent: re-running upserts in place, and backfilled data upgrades labels" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      generator.generate(from: t0, to: t0)
      expect(PathDependentLabel.count).to eq(2)
      expect(labels_for(0).fetch("long").label).to eq("unresolved")

      # Backfill arrives; the same run now resolves the race — same rows.
      make_candle(1, high: 102.5, low: 99.9, close: 102.0)
      generator.generate(from: t0, to: t0)

      expect(PathDependentLabel.count).to eq(2)
      expect(labels_for(0).fetch("long").label).to eq("win")
    end

    it "keeps shapes distinct: another tp/sl/horizon coexists on the same bars" do
      make_candle(0, high: 100.5, low: 99.5, close: 100.0)
      make_candle(1, high: 101.3, low: 99.9, close: 101.0) # hits 1.2% tp, not 2%

      generator.generate(from: t0, to: t0)
      described_class.new(symbol: symbol, tp_frac: 0.012, sl_frac: 0.008, horizon: 5)
        .generate(from: t0, to: t0)

      expect(PathDependentLabel.count).to eq(4)
      narrow = PathDependentLabel.for_shape(tp_frac: 0.012, sl_frac: 0.008, horizon: 5)
        .find_by(direction: "long")
      expect(narrow.label).to eq("win")
      wide = PathDependentLabel.for_shape(tp_frac: 0.02, sl_frac: 0.012, horizon: 5)
        .find_by(direction: "long")
      expect(wide.label).to eq("unresolved")
    end

    it "labels every bar in the range and reads lookahead candles beyond `to`" do
      (0..3).each { |k| make_candle(k, high: 100.4, low: 99.6, close: 100.0) }
      make_candle(4, high: 102.5, low: 99.9, close: 102.0) # beyond `to`, resolves bar 3

      result = generator.generate(from: t0, to: t0 + 3 * 300)

      expect(result).to eq({bars: 4, rows_written: 8})
      expect(labels_for(3).fetch("long").label).to eq("win")
      # No labels are written for bars beyond `to`.
      expect(PathDependentLabel.where(bar_timestamp: t0 + 4 * 300)).to be_empty
    end
  end
end
