# frozen_string_literal: true

require "rails_helper"

# Swing exposure reporting (issue #234 tail).
#
# `get_swing_position_summary` accumulated both `total_exposure` and the
# per-asset exposure as `position.size * current_price`, dropping contract_size.
# On NOL (contract_size 10) every exposure figure the swing summary reports —
# and everything downstream that buckets on it — read 10x too small.
RSpec.describe Trading::SwingPositionManager, "exposure notional" do
  let(:logger) { instance_double(Logger).as_null_object }
  let(:coinbase_client) { instance_double(Coinbase::AdvancedTradeClient) }
  let(:manager) { described_class.new(logger: logger) }

  before do
    allow(Trading::CoinbasePositions).to receive(:new).and_return(instance_double(Trading::CoinbasePositions))
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(instance_double(MarketData::FuturesContractManager))
    allow(Coinbase::AdvancedTradeClient).to receive(:new).and_return(coinbase_client)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10)
  end

  # 3 contracts * $90 mark * contract_size 10 = $2,700. Blind math gave $270.
  let!(:position) do
    create(:position, :swing_trading, product_id: "NOL-19AUG26-CDE",
      side: "LONG", size: 3, entry_price: 80.0)
  end

  context "with a live mark" do
    before { allow(coinbase_client).to receive(:market_price).and_return(90.0) }

    it "counts contract_size in total exposure" do
      expect(manager.get_swing_position_summary[:total_exposure]).to be_within(1e-6).of(2700.0)
    end

    it "counts contract_size in per-asset exposure" do
      by_asset = manager.get_swing_position_summary[:positions_by_asset]

      expect(by_asset["NOL"][:exposure]).to be_within(1e-6).of(2700.0)
    end
  end

  # The entry-price fallback path must be contract_size-aware too — it was the
  # same blind expression.
  context "when the mark is unavailable" do
    before { allow(coinbase_client).to receive(:market_price).and_return(nil) }

    it "falls back to contract_size-aware notional at entry" do
      expect(manager.get_swing_position_summary[:total_exposure]).to be_within(1e-6).of(2400.0)
    end
  end
end
