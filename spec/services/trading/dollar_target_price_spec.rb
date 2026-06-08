# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::DollarTargetPrice do
  let(:position) do
    create(:position, side: "LONG", entry_price: 91.62, size: 1.0, product_id: "NOL-19JUN26-CDE")
  end

  before do
    allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
  end

  describe ".price_for" do
    it "converts dollar profit to take-profit price for LONG" do
      price = described_class.price_for(position: position, field: :take_profit, dollar_amount: 10)

      expect(price).to be_within(0.001).of(92.62)
    end

    it "converts dollar loss to stop-loss price for LONG" do
      price = described_class.price_for(position: position, field: :stop_loss, dollar_amount: 5)

      expect(price).to be_within(0.001).of(91.12)
    end

    context "SHORT position" do
      let(:position) do
        create(:position, :short, entry_price: 100.0, size: 2.0, product_id: "BIT-26JUN26-CDE")
      end

      before do
        allow(Trading::ContractSizeResolver).to receive(:for_product).with("BIT-26JUN26-CDE").and_return(1)
      end

      it "converts dollar profit to take-profit price below entry" do
        price = described_class.price_for(position: position, field: :take_profit, dollar_amount: 20)

        expect(price).to be_within(0.001).of(90.0)
      end

      it "converts dollar loss to stop-loss price above entry" do
        price = described_class.price_for(position: position, field: :stop_loss, dollar_amount: 10)

        expect(price).to be_within(0.001).of(105.0)
      end
    end

    it "rejects non-positive dollar amounts" do
      expect {
        described_class.price_for(position: position, field: :take_profit, dollar_amount: 0)
      }.to raise_error(ArgumentError, /positive/i)
    end
  end

  describe ".parse_input" do
    it "parses dollar input with leading dollar sign" do
      result = described_class.parse_input("$10")
      expect(result).to eq(dollar_amount: 10.0)
    end

    it "parses plain price input" do
      result = described_class.parse_input("92.62")
      expect(result).to eq(price: 92.62)
    end

    it "rejects blank input" do
      expect(described_class.parse_input("  ")).to be_nil
    end
  end

  describe ".resolve" do
    it "returns price directly for numeric price input" do
      price, error = described_class.resolve(
        position: position,
        field: :take_profit,
        raw_input: "95.5"
      )

      expect(error).to be_nil
      expect(price).to eq(95.5)
    end

    it "converts dollar input to price" do
      price, error = described_class.resolve(
        position: position,
        field: :take_profit,
        raw_input: "$10"
      )

      expect(error).to be_nil
      expect(price).to be_within(0.001).of(92.62)
    end
  end
end
