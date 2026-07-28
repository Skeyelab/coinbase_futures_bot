# frozen_string_literal: true

require "rails_helper"

# Portfolio exposure on the analysis surface (issue #234 tail).
#
# `largest_position` and `assess_position_risk` both sized a position as
# `size * entry_price`, dropping contract_size. On NOL (contract_size 10) the
# reported dollar value was 10x too small, so `assess_position_risk` — which
# buckets on absolute dollars against POSITION_RISK_TIERS — returned "low" for
# exposure that is actually "high", and `largest_position` could name the wrong
# position as largest when two contracts have different contract sizes.
RSpec.describe MarketAnalysisService, "notional" do
  subject(:service) { described_class.new(symbol: "NOL-19AUG26-CDE") }

  # Same contract count and price, different contract_size. Blind math calls
  # these equal; they differ by 1000x.
  let(:nol) { instance_double(Position, product_id: "NOL-19AUG26-CDE", side: "LONG", size: 2, entry_price: 400.0) }
  let(:bip) { instance_double(Position, product_id: "BIP-20DEC30-CDE", side: "LONG", size: 2, entry_price: 400.0) }

  before do
    allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19AUG26-CDE").and_return(10)
    allow(Trading::ContractSizeResolver).to receive(:for_product).with("BIP-20DEC30-CDE").and_return(0.01)
  end

  describe "#assess_position_risk" do
    # 2 * $400 * 10 = $8,000 -> "medium" tier (5,000..15,000).
    # Blind math gave $800, which is under the $1,000 floor and read "low".
    it "buckets on contract_size-aware exposure" do
      expect(service.send(:assess_position_risk, [nol])).to eq("medium")
    end

    # 2 * $400 * 0.01 = $8 -> genuinely "low". Blind math gave $800, also
    # "low", so only the NOL case above separates the two.
    it "does not inflate a fractional contract's exposure" do
      expect(service.send(:assess_position_risk, [bip])).to eq("low")
    end
  end

  describe "#largest_position" do
    it "picks the largest by contract_size-aware notional, not contract count" do
      result = service.send(:largest_position, [bip, nol])

      expect(result[:symbol]).to eq("NOL-19AUG26-CDE")
      expect(result[:value]).to eq(8000.0)
    end
  end
end
