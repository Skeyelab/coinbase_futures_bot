# frozen_string_literal: true

require "rails_helper"

# Issue #568 rank-3 / #569: the runner that judges FundingSkewContrarian with
# BOTH #541 gates over the walk-forward harness. Plateau axes are the
# strategy's own knobs mapped onto the gate's historical keys: stop_scale
# carries the WINDOW scale, target_scale carries the ENTRY_Z scale.
#
# The local DB has no real BIP/BTC-USD history, so the regimes are
# constructed: a persistent-premium regime the contrarian must profit in, and
# a mean-reverting noise regime it must stay FLAT in (no churn).
RSpec.describe Backtest::FundingSkewEvaluation, type: :service do
  let(:perp) { "BIP-SKEWEVAL-TEST" }
  let(:spot) { "SPOT-SKEWEVAL-TEST" }
  let(:t0) { Time.parse("2026-03-01T00:00:00Z") }

  let(:calm_amplitude) { 0.0005 } # alternating +-5 bps: nonzero variance, |z| ~ 0.9, inside band

  # Premium per hour index. Noise: alternating +-calm forever. Spike regime:
  # a 12h cycle — 8 calm hours, then a +200 bps premium spike decaying back
  # over 4 hours (crowded longs paying, then normalizing).
  def premium_at(i, regime)
    calm = i.even? ? calm_amplitude : -calm_amplitude
    return calm if regime == :noise

    case i % 12
    when 8 then 0.02
    when 9 then 0.013
    when 10 then 0.006
    when 11 then 0.0
    else calm
    end
  end

  # One 1m candle per hour per leg feeds the proxy; hourly perp candles drive
  # the engine, spanning prev-close..close so touch fills are reachable.
  def seed_regime(regime, from:, to:)
    minute_rows = []
    hourly_rows = []
    prev = nil
    t = from
    i = 0
    while t <= to
      price = 100.0 * (1.0 + premium_at(i, regime))
      minute_rows << candle_row(perp, "1m", t, price, price, price)
      minute_rows << candle_row(spot, "1m", t, 100.0, 100.0, 100.0)
      hi = [prev || price, price].max * 1.0005
      lo = [prev || price, price].min * 0.9995
      hourly_rows << candle_row(perp, "1h", t, price, hi, lo, open: prev || price)
      prev = price
      t += 1.hour
      i += 1
    end
    Candle.insert_all!(minute_rows + hourly_rows)
  end

  def candle_row(symbol, timeframe, timestamp, close, high, low, open: close)
    {symbol: symbol, timeframe: timeframe, timestamp: timestamp,
     open: open, high: high, low: low, close: close, volume: 10,
     created_at: Time.current, updated_at: Time.current}
  end

  let(:config) do
    {window: 6, entry_z: 2.0, exit_z: 0.5, stop: 0.05, spot_symbol: spot}
  end

  describe ".run" do
    it "profits in the constructed persistent-premium regime and reports both gate verdicts" do
      seed_regime(:spike, from: t0 - 12.hours, to: t0 + 4.days)

      result = described_class.run(symbol: perp, from: t0, to: t0 + 4.days,
        train_span: 1.day, eval_span: 1.day, config: config, fee_rate: 0.0003)

      aggregate = result[:walk_forward][:aggregate]
      expect(aggregate[:trade_count]).to be > 0
      expect(aggregate[:total_pnl]).to be > 0
      expect(aggregate[:total_fees]).to be > 0 # taker entries pay — part of the test

      plateau = result[:plateau]
      expect(plateau[:gate]).to eq("parameter_plateau")
      expect(plateau[:cell_count]).to eq(25)
      expect(plateau[:baseline]).to include(stop_scale: 1.0, target_scale: 1.0)

      pessimistic = result[:pessimistic_cost]
      expect(pessimistic[:gate]).to eq("pessimistic_cost")
      expect(pessimistic[:multiples].map { |m| m[:multiple] }).to eq([1.5, 2.0])

      expect(result[:passed]).to eq(plateau[:passed] && pessimistic[:passed])
      expect(result[:config]).to include(window: 6, entry_z: 2.0)
    end
  end

  describe "flat in noise (no churn)" do
    it "takes zero trades when the premium never leaves the z band" do
      seed_regime(:noise, from: t0 - 12.hours, to: t0 + 4.days)

      report = Backtest::WalkForward.new(symbol: perp, step: "1h",
        strategy: Strategy::FundingSkewContrarian.new(config), fee_rate: 0.0003)
        .run(from: t0, to: t0 + 4.days, train_span: 1.day, eval_span: 1.day)

      expect(report[:aggregate][:trade_count]).to eq(0)
    end
  end
end
