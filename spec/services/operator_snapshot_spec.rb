# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorSnapshot do
  let(:now) { Time.utc(2026, 7, 17, 18, 0, 0) }

  subject(:snapshot) { described_class.new(now: now) }

  describe "#status" do
    it "reports halt, dry-run, position counts, signals, and an ISO-8601 as_of" do
      create(:position, day_trading: true)
      create(:position, :swing_trading)
      create(:signal_alert)
      DryRun.enable!
      TradingHalt.halt!(reason: "CPI print")

      result = snapshot.status

      expect(result[:as_of]).to eq("2026-07-17T18:00:00Z")
      expect(result[:halt]).to include(active: false, halted: true, reason: "CPI print")
      expect(result[:dry_run]).to eq({active: true})
      expect(result[:positions]).to include(day: 1, swing: 1, open_total: 2)
      expect(result[:signals]).to eq({active: 1})
    end

    it "serializes cleanly to JSON with no ANSI escape codes" do
      json = JSON.generate(snapshot.status)

      expect { JSON.parse(json) }.not_to raise_error
      expect(json).not_to match(/\e\[/)
    end
  end

  describe "#positions" do
    it "returns snake_case position rows with contract-size-aware unrealized PnL and a paper flag" do
      create(:position, product_id: "NOL-19JUN26-CDE", side: "SHORT", entry_price: 93.62, size: 1,
        day_trading: false, paper: true)
      allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
      allow(RecentMarketPrice).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(93.46)

      row = snapshot.positions[:positions].first

      expect(row).to include(
        product_id: "NOL-19JUN26-CDE",
        side: "SHORT",
        entry_price: 93.62,
        size: 1.0,
        paper: true
      )
      # (93.62 - 93.46) * 1 * 10 = 1.60
      expect(row[:unrealized_pnl]).to eq(1.6)
    end
  end

  describe "#signals" do
    it "returns snake_case signal rows with an ISO-8601 timestamp" do
      create(:signal_alert, symbol: "OIL-USD", side: "long", confidence: 82, strategy_name: "trend",
        alert_timestamp: now - 60)

      row = snapshot.signals[:signals].first

      expect(row).to include(symbol: "OIL-USD", side: "long", confidence: 82, strategy: "trend")
      expect(row[:timestamp]).to eq("2026-07-17T17:59:00Z")
    end
  end
end
