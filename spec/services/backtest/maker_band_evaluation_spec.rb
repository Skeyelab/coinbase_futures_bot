# frozen_string_literal: true

require "rails_helper"

# Issue #568: the runner that judges MakerBandReversion with BOTH #541 gates —
# ParameterPlateau (5x5 around the k/N baseline) and PessimisticCost
# (1.5x/2x) — over the walk-forward harness. The plateau axes are mapped onto
# the gate's historical key names: stop_scale carries the N (period) scale,
# target_scale carries the k (band width) scale.
RSpec.describe Backtest::MakerBandEvaluation, type: :service do
  let(:t0) { Time.parse("2026-03-01T00:00:00Z") }
  let(:symbol) { "BIP-TEST-PERP" }

  # Mean-reverting fixture: a sine wave around 100, 1h period on 5m bars,
  # +-40 bps amplitude, with highs/lows wide enough for through-price fills.
  def seed_sine_candles(from:, to:)
    rows = []
    t = from
    i = 0
    while t <= to
      close = 100.0 * (1 + 0.004 * Math.sin(2 * Math::PI * i / 12.0))
      rows << {symbol: symbol, timeframe: "5m", timestamp: t,
               open: close, high: close * 1.0015, low: close * 0.9985, close: close, volume: 10,
               created_at: Time.current, updated_at: Time.current}
      t += 5.minutes
      i += 1
    end
    Candle.insert_all!(rows)
  end

  let(:config) do
    {anchor_period: 12, vol_period: 12, band_k: 1.0, stop_m: 2.0, min_band_bps: 1.0}
  end

  describe ".run" do
    it "returns walk-forward metrics plus verdicts from both gates" do
      from = t0
      to = t0 + 3.days
      seed_sine_candles(from: from - 1.day, to: to)

      result = described_class.run(symbol: symbol, from: from, to: to,
        train_span: 1.day, eval_span: 1.day, config: config)

      expect(result[:walk_forward][:aggregate]).to include(:trade_count, :total_pnl)
      expect(result[:walk_forward][:aggregate][:trade_count]).to be > 0

      plateau = result[:plateau]
      expect(plateau[:gate]).to eq("parameter_plateau")
      expect(plateau[:cell_count]).to eq(25)
      expect(plateau[:baseline]).to include(stop_scale: 1.0, target_scale: 1.0)

      pessimistic = result[:pessimistic_cost]
      expect(pessimistic[:gate]).to eq("pessimistic_cost")
      expect(pessimistic[:multiples].map { |m| m[:multiple] }).to eq([1.5, 2.0])

      expect(result[:passed]).to eq(plateau[:passed] && pessimistic[:passed])
    end

    it "records the baseline config it evaluated" do
      from = t0
      to = t0 + 3.days
      seed_sine_candles(from: from - 1.day, to: to)

      result = described_class.run(symbol: symbol, from: from, to: to,
        train_span: 1.day, eval_span: 1.day, config: config)

      expect(result[:config]).to include(band_k: 1.0, anchor_period: 12, vol_period: 12)
    end
  end

  describe "trend failure mode (documented)" do
    it "loses on a regime break: the reversion quote fills into a fall that keeps falling" do
      rows = []
      # 30 oscillating bars around 100, then a -1%/bar slide for 10 bars.
      closes = (0...30).map { |i| 100.0 * (1 + 0.002 * Math.sin(2 * Math::PI * i / 12.0)) }
      closes += (1..10).map { |i| closes.last * 0.99**i }
      closes.each_with_index do |close, i|
        rows << {symbol: symbol, timeframe: "5m", timestamp: t0 + i * 5.minutes,
                 open: close, high: close * 1.0015, low: close * 0.9985, close: close, volume: 10,
                 created_at: Time.current, updated_at: Time.current}
      end
      Candle.insert_all!(rows)

      strategy = Strategy::MakerBandReversion.new(config)
      engine = Backtest::Engine.new(symbol: symbol, strategy: strategy, step: "5m",
        fill_model: :through_price, maker_fee_rate: 0.0, slippage: 0.0002,
        starting_equity: 10_000.0)
      result = engine.run(from: t0 + 15 * 5.minutes, to: t0 + 39 * 5.minutes)

      expect(result.trade_count).to be > 0
      expect(result.total_pnl).to be < 0
    end
  end
end
