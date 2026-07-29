# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::DatasetBuilder do
  include MlSeriesHelper

  let(:symbol) { "AAA-20DEC30-CDE" }
  let(:t0) { Time.utc(2026, 1, 1) }
  let(:shape) { {tp_frac: 0.02, sl_frac: 0.012, horizon: 12} }
  let(:builder) do
    described_class.new(symbols: [symbol], direction: "long", timeframe: "5m",
      extractor_config: tiny_extractor_config, **shape)
  end

  before { seed_series(symbol, start_at: t0, hours: 8) }

  def create_label(ts, label, direction: "long")
    PathDependentLabel.create!(symbol: symbol, timeframe: "5m", bar_timestamp: ts,
      direction: direction, label: label, **shape)
  end

  describe "#rows" do
    it "joins labels to features on the bar timestamp and encodes win-vs-rest" do
      win_ts = t0 + 5.hours
      loss_ts = t0 + 5.hours + 300
      unresolved_ts = t0 + 5.hours + 600
      create_label(win_ts, "win")
      create_label(loss_ts, "loss")
      create_label(unresolved_ts, "unresolved")

      rows = builder.rows(from: t0 + 5.hours, to: t0 + 6.hours)

      expect(rows.map { |r| r[:timestamp] }).to eq([win_ts, loss_ts, unresolved_ts])
      expect(rows.map { |r| r[:y] }).to eq([1, 0, 0])
      expect(rows.first[:symbol]).to eq(symbol)
      expect(rows.first[:features].keys).to match_array(Ml::FeatureExtractor::FEATURE_NAMES)
    end

    it "drops labeled bars whose features are unavailable (insufficient history)" do
      early_ts = t0 + 600 # far too early for any EMA window
      create_label(early_ts, "win")

      expect(builder.rows(from: t0, to: t0 + 1.hour)).to be_empty
    end

    it "ignores bars that have features but no label row" do
      create_label(t0 + 5.hours, "win")

      rows = builder.rows(from: t0 + 5.hours, to: t0 + 7.hours)
      expect(rows.size).to eq(1)
    end

    it "only reads labels for the requested direction" do
      create_label(t0 + 5.hours, "win", direction: "short")

      expect(builder.rows(from: t0 + 5.hours, to: t0 + 6.hours)).to be_empty
    end

    it "only reads labels for the requested shape" do
      PathDependentLabel.create!(symbol: symbol, timeframe: "5m",
        bar_timestamp: t0 + 5.hours, direction: "long", label: "win",
        tp_frac: 0.04, sl_frac: 0.02, horizon: 12)

      expect(builder.rows(from: t0 + 5.hours, to: t0 + 6.hours)).to be_empty
    end

    it "pools multiple symbols into one time-ordered dataset" do
      other = "BBB-20DEC30-CDE"
      seed_series(other, start_at: t0, hours: 8, base: 250.0)
      create_label(t0 + 5.hours, "win")
      PathDependentLabel.create!(symbol: other, timeframe: "5m",
        bar_timestamp: t0 + 5.hours + 300, direction: "long", label: "loss", **shape)

      rows = described_class.new(symbols: [symbol, other], direction: "long",
        timeframe: "5m", extractor_config: tiny_extractor_config, **shape)
        .rows(from: t0 + 5.hours, to: t0 + 6.hours)

      expect(rows.map { |r| r[:symbol] }).to eq([symbol, other])
      expect(rows.map { |r| r[:timestamp] }).to eq(rows.map { |r| r[:timestamp] }.sort)
    end
  end
end
