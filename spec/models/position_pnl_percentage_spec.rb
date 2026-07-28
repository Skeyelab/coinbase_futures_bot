# frozen_string_literal: true

require "rails_helper"

# `pnl_percentage` divided a contract_size-AWARE numerator by a contract_size-
# BLIND denominator (issue #234 tail).
#
# `pnl` is written by #unrealized_pnl_at -> Trading::FuturesUnrealizedPnl, which
# multiplies by contract_size. The denominator was `entry_price * size`, which
# does not. The ratio is therefore off by exactly contract_size: 10x too large
# on NOL, 100x too small on BIP. A unit mismatch, not a rounding error.
RSpec.describe Position, "#pnl_percentage" do
  # $1 move on 2 contracts of a contract_size 10 future = $20 realized.
  # Notional at entry is 2 * $80 * 10 = $1,600, so the return is 1.25%.
  # The blind denominator ($160) reported 12.5%.
  context "on a contract_size 10 future (NOL)" do
    before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10) }

    let(:position) do
      create(:position, :closed, product_id: "NOL-19AUG26-CDE",
        side: "LONG", size: 2, entry_price: 80.0, pnl: 20.0)
    end

    it "measures return against contract_size-aware notional" do
      expect(position.pnl_percentage).to eq(1.25)
    end
  end

  # The other direction. 3 contracts * $100,000 * 0.01 = $3,000 notional;
  # a $30 gain is 1%. The blind denominator ($300,000) reported 0.01%.
  context "on a contract_size 0.01 future (BIP)" do
    before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01) }

    let(:position) do
      create(:position, :closed, product_id: "BIP-20DEC30-CDE",
        side: "LONG", size: 3, entry_price: 100_000.0, pnl: 30.0)
    end

    it "measures return against contract_size-aware notional" do
      expect(position.pnl_percentage).to eq(1.0)
    end
  end

  it "returns nil while the position is still open" do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10)
    open_position = create(:position, product_id: "NOL-19AUG26-CDE", size: 2, entry_price: 80.0)

    expect(open_position.pnl_percentage).to be_nil
  end

  # A resolver failure returns DEFAULT_CONTRACT_SIZE (1) and a zero-notional
  # position must not raise a ZeroDivisionError on a reporting surface.
  it "returns nil rather than dividing by zero notional" do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0)
    position = create(:position, :closed, product_id: "NOL-19AUG26-CDE",
      size: 2, entry_price: 80.0, pnl: 20.0)

    expect(position.pnl_percentage).to be_nil
  end
end
