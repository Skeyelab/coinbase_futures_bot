# frozen_string_literal: true

require "rails_helper"

RSpec.describe Labels::Reachability do
  let(:symbol) { "BIP-20DEC30-CDE" }
  let(:t0) { Time.utc(2026, 1, 1) }

  def write_label(offset_bars, direction, label, horizon: 4)
    PathDependentLabel.create!(symbol: symbol, timeframe: "5m",
      bar_timestamp: t0 + offset_bars * 300, tp_frac: 0.02, sl_frac: 0.012,
      horizon: horizon, direction: direction, label: label,
      resolved_at_bars: (label == "unresolved") ? nil : 1)
  end

  describe ".report" do
    it "computes winnable share per direction plus the honest effective-n caveat" do
      # 8 bars long: 3 win, 3 loss, 2 unresolved. Horizon 4 -> effective n = 2.
      %w[win win win loss loss loss unresolved unresolved].each_with_index do |label, i|
        write_label(i, "long", label)
      end
      %w[win loss loss loss loss loss loss loss].each_with_index do |label, i|
        write_label(i, "short", label)
      end

      report = described_class.report(symbol: symbol, tp_frac: 0.02, sl_frac: 0.012, horizon: 4)

      long = report.fetch(:long)
      expect(long[:n]).to eq(8)
      expect(long[:wins]).to eq(3)
      expect(long[:losses]).to eq(3)
      expect(long[:unresolved]).to eq(2)
      expect(long[:winnable_pct]).to be_within(0.001).of(37.5)
      expect(long[:win_rate_resolved_pct]).to be_within(0.001).of(50.0)
      expect(long[:effective_n]).to eq(2)

      short = report.fetch(:short)
      expect(short[:winnable_pct]).to be_within(0.001).of(12.5)
      expect(short[:effective_n]).to eq(2)
    end

    it "ignores rows from other shapes" do
      write_label(0, "long", "win")
      PathDependentLabel.create!(symbol: symbol, timeframe: "5m",
        bar_timestamp: t0, tp_frac: 0.012, sl_frac: 0.008, horizon: 4,
        direction: "long", label: "loss", resolved_at_bars: 1)

      report = described_class.report(symbol: symbol, tp_frac: 0.02, sl_frac: 0.012, horizon: 4)

      expect(report.fetch(:long)[:n]).to eq(1)
      expect(report.fetch(:long)[:wins]).to eq(1)
    end
  end
end
