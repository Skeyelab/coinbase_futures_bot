# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::Result do
  let(:trades) do
    [
      {side: :long, entry_price: 100.0, exit_price: 101.0, quantity: 10.0, pnl: 100.0, fees: 10.0,
       entered_at: Time.utc(2026, 1, 1, 10), exited_at: Time.utc(2026, 1, 1, 12)},
      {side: :long, entry_price: 101.0, exit_price: 100.5, quantity: 10.0, pnl: -50.0, fees: 8.0,
       entered_at: Time.utc(2026, 1, 2, 10), exited_at: Time.utc(2026, 1, 2, 11)},
      {side: :short, entry_price: 102.0, exit_price: 101.4, quantity: 10.0, pnl: 60.0, fees: 9.0,
       entered_at: Time.utc(2026, 1, 3, 10), exited_at: Time.utc(2026, 1, 3, 15)}
    ]
  end
  let(:equity_curve) { [10_000.0, 10_100.0, 10_050.0, 10_110.0] }

  subject(:result) do
    described_class.new(trades: trades, equity_curve: equity_curve, starting_equity: 10_000.0,
      from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 4))
  end

  it "counts trades and computes total PnL" do
    expect(result.trade_count).to eq(3)
    expect(result.total_pnl).to be_within(1e-9).of(110.0)
  end

  it "computes win rate" do
    expect(result.win_rate).to be_within(1e-9).of(2.0 / 3)
  end

  it "computes max drawdown as a fraction of the running peak" do
    # peak 10_100 -> trough 10_050
    expect(result.max_drawdown).to be_within(1e-6).of(50.0 / 10_100.0)
  end

  it "computes a Sharpe-like ratio from per-trade PnL" do
    # mean/std(sample) * sqrt(n) for pnls [100, -50, 60]
    expect(result.sharpe_like).to be_within(0.01).of(0.82)
  end

  it "surfaces round-trip costs relative to the average win (issue #353)" do
    expect(result.total_fees).to be_within(1e-9).of(27.0)
    expect(result.avg_win).to be_within(1e-9).of(80.0)
    expect(result.avg_loss).to be_within(1e-9).of(-50.0)
    expect(result.cost_per_round_trip).to be_within(1e-9).of(9.0)
    expect(result.cost_pct_of_avg_win).to be_within(1e-6).of(11.25)
  end

  it "serializes to a JSON-friendly hash" do
    h = result.to_h
    expect(h[:trade_count]).to eq(3)
    expect(h[:from]).to eq("2026-01-01T00:00:00Z")
    expect(h[:final_equity]).to eq(10_110.0)
    expect { JSON.generate(h) }.not_to raise_error
  end

  context "with no trades" do
    subject(:result) do
      described_class.new(trades: [], equity_curve: [10_000.0], starting_equity: 10_000.0,
        from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 4))
    end

    it "returns safe values instead of dividing by zero" do
      expect(result.trade_count).to eq(0)
      expect(result.total_pnl).to eq(0.0)
      expect(result.win_rate).to be_nil
      expect(result.max_drawdown).to eq(0.0)
      expect(result.sharpe_like).to be_nil
      expect(result.cost_pct_of_avg_win).to be_nil
    end
  end
end
