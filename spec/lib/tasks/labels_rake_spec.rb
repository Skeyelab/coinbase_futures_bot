# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "labels rake tasks" do
  before(:all) do
    Rake::Task.clear
    Rails.application.load_tasks
  end

  before { Rake::Task.tasks.each(&:reenable) }

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  let(:symbol) { "BIP-20DEC30-CDE" }
  let(:t0) { Time.utc(2026, 1, 1) }

  describe "labels:generate" do
    it "writes labels and prints a JSON summary" do
      create(:candle, :five_minute, symbol: symbol, timestamp: t0,
        open: 100.0, high: 100.5, low: 99.5, close: 100.0)
      create(:candle, :five_minute, symbol: symbol, timestamp: t0 + 300,
        open: 100.0, high: 102.5, low: 99.9, close: 102.0)

      output = capture_stdout do
        expect {
          Rake::Task["labels:generate"].invoke(symbol, "2026-01-01 00:00", "2026-01-01 00:00")
        }.to change(PathDependentLabel, :count).by(2)
      end

      summary = JSON.parse(output)
      expect(summary).to include("bars" => 1, "rows_written" => 2, "symbol" => symbol)
      expect(summary["tp_frac"]).to eq(0.02)
      expect(summary["horizon"]).to eq(288)
    end
  end

  describe "labels:reachability" do
    it "prints per-symbol winnable shares with raw n and effective n" do
      %w[win loss unresolved].each_with_index do |label, i|
        PathDependentLabel.create!(symbol: symbol, timeframe: "5m",
          bar_timestamp: t0 + i * 300, tp_frac: 0.02, sl_frac: 0.012, horizon: 288,
          direction: "long", label: label,
          resolved_at_bars: (label == "unresolved") ? nil : 1)
      end

      output = capture_stdout do
        Rake::Task["labels:reachability"].invoke(symbol)
      end

      report = JSON.parse(output)
      long = report.fetch("symbols").fetch(symbol).fetch("long")
      expect(long["n"]).to eq(3)
      expect(long["winnable_pct"]).to be_within(0.01).of(33.33)
      expect(long["effective_n"]).to eq(0) # 3 bars / 288 horizon — honestly zero
    end
  end
end
