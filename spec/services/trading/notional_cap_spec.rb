# frozen_string_literal: true

require "rails_helper"

# Issue #437 / #392 condition 2. Nothing bounded total account notional —
# grepping for notional_cap|equity_cap|max_notional returned nothing. Existing
# caps bound CONTRACT COUNT, which is meaningless across a mixed universe: one
# NOL contract is ~$930 and one BTC nano is ~$100, so "max 5" means two
# different exposures. And nothing summed across concurrent positions at all.
RSpec.describe Trading::NotionalCap, type: :service do
  let(:equity) { 1_000.0 }

  before do
    Position.destroy_all
    allow(Trading::CurrentEquity).to receive(:usd).and_return(equity)
  end

  def open_position!(product_id:, size:, entry_price:)
    create(:position, product_id: product_id, size: size, entry_price: entry_price, status: "OPEN")
  end

  describe ".limit_usd" do
    it "is a multiple of CURRENT equity, so it scales with the account" do
      expect(described_class.limit_usd).to eq(equity * described_class.multiple)
    end

    it "is configurable" do
      ClimateControl.modify(ACCOUNT_NOTIONAL_MULTIPLE: "1.5") do
        expect(described_class.multiple).to eq(1.5)
        expect(described_class.limit_usd).to eq(1_500.0)
      end
    end
  end

  describe ".open_notional_usd" do
    it "sums across ALL concurrent open positions, not per symbol" do
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
      open_position!(product_id: "BIP-20DEC30-CDE", size: 1, entry_price: 650.0)
      open_position!(product_id: "NOL-19AUG26-CDE", size: 1, entry_price: 900.0)

      expect(described_class.open_notional_usd).to be_within(0.01).of(1_550.0)
    end

    it "is zero with nothing open" do
      expect(described_class.open_notional_usd).to eq(0.0)
    end
  end

  describe ".room_usd" do
    it "reports what is left under the cap" do
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
      open_position!(product_id: "BIP-20DEC30-CDE", size: 1, entry_price: 650.0)

      expect(described_class.room_usd).to be_within(0.01).of(described_class.limit_usd - 650.0)
    end

    it "never reports negative room" do
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
      open_position!(product_id: "BIP-20DEC30-CDE", size: 100, entry_price: 650.0)

      expect(described_class.room_usd).to eq(0.0)
    end
  end

  describe ".allows?" do
    before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0) }

    it "permits an entry that fits" do
      expect(described_class.allows?(product_id: "BIP-20DEC30-CDE", quantity: 1, price: 650.0)).to be true
    end

    # The case the issue was filed for: 2% risk sizing at a 40 bps stop sizes to
    # ~7 contracts, ~4.6x a $1k account.
    it "refuses an entry that alone breaches the cap" do
      expect(described_class.allows?(product_id: "BIP-20DEC30-CDE", quantity: 7, price: 650.0)).to be false
    end

    # Per-position checks cannot catch this: each entry is small, the SUM is not.
    it "refuses an entry that breaches only when stacked on what is already open" do
      open_position!(product_id: "NOL-19AUG26-CDE", size: 1, entry_price: 900.0)
      open_position!(product_id: "BIT-29AUG26-CDE", size: 1, entry_price: 900.0)

      expect(described_class.allows?(product_id: "BIP-20DEC30-CDE", quantity: 1, price: 650.0)).to be false
    end

    it "is disabled by a non-positive multiple" do
      ClimateControl.modify(ACCOUNT_NOTIONAL_MULTIPLE: "0") do
        expect(described_class.allows?(product_id: "BIP-20DEC30-CDE", quantity: 999, price: 650.0)).to be true
      end
    end

    # Refusing to trade because equity is unreadable would be its own outage;
    # the loss caps and halt still bound the damage.
    it "permits when equity cannot be read, rather than blocking all trading" do
      allow(Trading::CurrentEquity).to receive(:usd).and_return(0.0)

      expect(described_class.allows?(product_id: "BIP-20DEC30-CDE", quantity: 1, price: 650.0)).to be true
    end
  end

  describe ".max_quantity" do
    before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0) }

    it "clamps to what the remaining room affords" do
      # $2,000 cap at 2x, $650/contract -> 3 contracts fit.
      expect(described_class.max_quantity(product_id: "BIP-20DEC30-CDE", price: 650.0)).to eq(3)
    end

    it "is zero once the cap is used up" do
      open_position!(product_id: "BIP-20DEC30-CDE", size: 4, entry_price: 650.0)

      expect(described_class.max_quantity(product_id: "BIP-20DEC30-CDE", price: 650.0)).to eq(0)
    end
  end

  # Capped is not the same as visible: without this an operator sees entries
  # refused with no way to know how close to the ceiling they are.
  it "appears in the operator status snapshot" do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
    open_position!(product_id: "BIP-20DEC30-CDE", size: 1, entry_price: 650.0)

    cap = OperatorSnapshot.new.status[:notional_cap]

    expect(cap).to include(enabled: true, limit_usd: 2_000.0)
    expect(cap[:open_notional_usd]).to be_within(0.01).of(650.0)
    expect(cap[:room_usd]).to be_within(0.01).of(1_350.0)
  end
end
