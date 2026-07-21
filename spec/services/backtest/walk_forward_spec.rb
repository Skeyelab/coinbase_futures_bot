# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::WalkForward, type: :service do
  let(:from) { Time.parse("2026-01-01T00:00:00Z") }
  let(:to) { Time.parse("2026-01-10T00:00:00Z") }

  let(:never_signals) do
    Class.new do
      def signal(symbol:, equity_usd:, as_of: nil)
        nil
      end
    end.new
  end

  it "rolls a train/eval window across the history and reports per-window out-of-sample metrics" do
    report = described_class.new(symbol: "TEST-USD", strategy: never_signals)
      .run(from: from, to: to, train_span: 3.days, eval_span: 2.days)

    windows = report[:windows]
    expect(windows.size).to eq(3)

    expect(windows[0][:train_from]).to eq(from.iso8601)
    expect(windows[0][:train_to]).to eq((from + 3.days).iso8601)
    expect(windows[0][:eval_from]).to eq((from + 3.days).iso8601)
    expect(windows[0][:eval_to]).to eq((from + 5.days).iso8601)

    expect(windows[1][:eval_from]).to eq((from + 5.days).iso8601)
    expect(windows[2][:eval_to]).to eq(to.iso8601)

    # Metrics are out-of-sample: computed on the eval span only
    windows.each do |w|
      expect(w[:metrics]).to include(:trade_count, :total_pnl, :win_rate, :max_drawdown, :sharpe_like)
    end
  end

  it "reports per-window data coverage so data-starved windows are visible (issue #378)" do
    # 5m candles across the whole span, 1m candles only in the last 2 days:
    # early windows must show one_minute coverage ~0, late ones > 0.
    (0...(9 * 288)).step(12).each do |i|
      Candle.create!(symbol: "TEST-USD", timeframe: "5m", timestamp: from + i * 5.minutes,
        open: 100, high: 101, low: 99, close: 100, volume: 1)
    end
    (0...(2 * 1440)).step(30).each do |i|
      Candle.create!(symbol: "TEST-USD", timeframe: "1m", timestamp: to - 2.days + i.minutes,
        open: 100, high: 101, low: 99, close: 100, volume: 1)
    end

    report = described_class.new(symbol: "TEST-USD", strategy: never_signals)
      .run(from: from, to: to, train_span: 3.days, eval_span: 2.days)

    coverages = report[:windows].map { |w| w[:data_coverage][:one_minute] }
    expect(coverages.first).to eq(0.0)
    expect(coverages.last).to be > 0.0
    expect(report[:windows].first[:data_coverage][:five_minute]).to be > 0.0
  end

  it "aggregates across windows" do
    report = described_class.new(symbol: "TEST-USD", strategy: never_signals)
      .run(from: from, to: to, train_span: 3.days, eval_span: 2.days)

    expect(report[:aggregate]).to include(
      window_count: 3,
      trade_count: 0,
      total_pnl: 0.0,
      expectancy: nil,
      cost_gate_passed: nil
    )
    expect { JSON.generate(report) }.not_to raise_error
  end

  it "raises when the span cannot fit a single window" do
    expect do
      described_class.new(symbol: "TEST-USD", strategy: never_signals)
        .run(from: from, to: from + 1.day, train_span: 3.days, eval_span: 2.days)
    end.to raise_error(ArgumentError, /window/i)
  end
end
