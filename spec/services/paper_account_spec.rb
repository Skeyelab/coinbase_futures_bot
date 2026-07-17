# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaperAccount do
  def paper_position(attrs = {})
    Position.create!({
      paper: true,
      product_id: "BIT-29AUG25-CDE",
      side: "LONG",
      size: 1.0,
      entry_price: 50_000.0,
      entry_time: 1.hour.ago,
      status: "OPEN",
      day_trading: true
    }.merge(attrs))
  end

  describe "#equity" do
    it "starts at the configured starting equity when there are no paper positions" do
      expect(described_class.new.equity).to eq(10_000.0)
    end

    it "adds realized PnL from closed paper positions" do
      paper_position(status: "CLOSED", pnl: 250.0, close_time: Time.current)

      expect(described_class.new.realized_pnl).to eq(250.0)
      expect(described_class.new.equity).to eq(10_250.0)
    end

    it "adds unrealized PnL from open paper positions marked to market" do
      paper_position(product_id: "NOL-19JUN26-CDE", side: "SHORT", entry_price: 93.62, day_trading: false)
      allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
      allow(RecentMarketPrice).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(93.46)

      # (93.62 - 93.46) * 1 contract * contract_size 10 = 1.60
      expect(described_class.new.unrealized_pnl).to eq(1.6)
    end

    it "ignores live (non-paper) positions" do
      Position.create!(paper: false, status: "CLOSED", pnl: 999.0, product_id: "BIT-29AUG25-CDE",
        side: "LONG", size: 1, entry_price: 50_000, entry_time: 1.hour.ago, close_time: Time.current, day_trading: true)

      expect(described_class.new.realized_pnl).to eq(0.0)
      expect(described_class.new.equity).to eq(10_000.0)
    end
  end

  describe "#open_positions" do
    it "returns only open paper positions" do
      open_p = paper_position
      paper_position(status: "CLOSED", pnl: 0, close_time: Time.current)

      expect(described_class.new.open_positions.to_a).to eq([open_p])
    end
  end

  describe "#any?" do
    it "is false with no paper positions and true once one exists" do
      expect(described_class.new.any?).to be false
      paper_position
      expect(described_class.new.any?).to be true
    end
  end
end
