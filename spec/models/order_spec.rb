# frozen_string_literal: true

require "rails_helper"

RSpec.describe Order, type: :model do
  let(:position) { create(:position) }

  let(:valid_attrs) do
    {
      position: position,
      contract_id: "BIT-29AUG25-CDE",
      side: "buy",
      order_type: "market",
      quantity: 1.0,
      status: "pending",
      placed_at: Time.current
    }
  end

  describe "validations" do
    it "is valid with valid attributes" do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it "requires contract_id" do
      order = described_class.new(valid_attrs.merge(contract_id: nil))
      expect(order).not_to be_valid
      expect(order.errors[:contract_id]).to be_present
    end

    it "requires side" do
      order = described_class.new(valid_attrs.merge(side: nil))
      expect(order).not_to be_valid
    end

    it "requires order_type" do
      order = described_class.new(valid_attrs.merge(order_type: nil))
      expect(order).not_to be_valid
    end

    it "requires quantity" do
      order = described_class.new(valid_attrs.merge(quantity: nil))
      expect(order).not_to be_valid
    end

    it "requires quantity > 0" do
      order = described_class.new(valid_attrs.merge(quantity: 0))
      expect(order).not_to be_valid
    end

    it "requires status" do
      order = described_class.new(valid_attrs.merge(status: nil))
      expect(order).not_to be_valid
    end

    it "rejects invalid side" do
      order = described_class.new(valid_attrs.merge(side: "long"))
      expect(order).not_to be_valid
    end

    it "rejects invalid order_type" do
      order = described_class.new(valid_attrs.merge(order_type: "stop"))
      expect(order).not_to be_valid
    end

    it "rejects invalid status" do
      order = described_class.new(valid_attrs.merge(status: "unknown"))
      expect(order).not_to be_valid
    end

    it "enforces unique coinbase_order_id" do
      uuid = SecureRandom.uuid
      create(:order, valid_attrs.merge(coinbase_order_id: uuid))
      dup = described_class.new(valid_attrs.merge(coinbase_order_id: uuid))
      expect(dup).not_to be_valid
    end

    it "allows nil coinbase_order_id (multiple orders without exchange id)" do
      create(:order, valid_attrs.merge(coinbase_order_id: nil))
      second = described_class.new(valid_attrs.merge(coinbase_order_id: nil))
      expect(second).to be_valid
    end
  end

  describe "associations" do
    it "belongs_to position optionally" do
      order = described_class.new(valid_attrs.merge(position: nil))
      expect(order).to be_valid
    end

    it "links back from position.orders" do
      order = create(:order, valid_attrs)
      expect(position.orders).to include(order)
    end

    it "nullifies position_id when position is destroyed" do
      order = create(:order, valid_attrs)
      position.destroy!
      expect(order.reload.position_id).to be_nil
    end
  end

  describe "scopes" do
    let!(:filled_order) { create(:order, valid_attrs.merge(status: "filled", fill_price: 50_100.0, filled_at: Time.current)) }
    let!(:pending_order) { create(:order, valid_attrs) }
    let!(:sell_order) { create(:order, valid_attrs.merge(side: "sell")) }

    it ".filled returns filled orders" do
      expect(described_class.filled).to include(filled_order)
      expect(described_class.filled).not_to include(pending_order)
    end

    it ".pending returns pending orders" do
      expect(described_class.pending).to include(pending_order)
      expect(described_class.pending).not_to include(filled_order)
    end

    it ".closing returns sell orders" do
      expect(described_class.closing).to include(sell_order)
      expect(described_class.closing).not_to include(pending_order)
    end
  end

  describe "#filled?" do
    it "returns true when status is filled" do
      order = described_class.new(valid_attrs.merge(status: "filled"))
      expect(order.filled?).to be true
    end

    it "returns false when status is pending" do
      expect(described_class.new(valid_attrs).filled?).to be false
    end
  end

  describe "#slippage" do
    it "returns nil when target_price is nil" do
      order = described_class.new(valid_attrs.merge(fill_price: 50_100.0, target_price: nil))
      expect(order.slippage).to be_nil
    end

    it "returns fill_price minus target_price" do
      order = described_class.new(valid_attrs.merge(target_price: 50_000.0, fill_price: 50_100.0))
      expect(order.slippage).to eq(100.0)
    end

    it "returns negative slippage for favorable fills" do
      order = described_class.new(valid_attrs.merge(target_price: 50_000.0, fill_price: 49_900.0))
      expect(order.slippage).to eq(-100.0)
    end
  end

  describe "#slippage_bps" do
    it "returns nil when target_price is nil" do
      order = described_class.new(valid_attrs.merge(fill_price: 50_100.0, target_price: nil))
      expect(order.slippage_bps).to be_nil
    end

    it "returns slippage in basis points" do
      order = described_class.new(valid_attrs.merge(target_price: 50_000.0, fill_price: 50_100.0))
      expect(order.slippage_bps).to be_within(0.01).of(20.0)
    end
  end
end
