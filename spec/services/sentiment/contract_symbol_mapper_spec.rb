# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::ContractSymbolMapper do
  describe ".sentiment_symbol_for" do
    [
      ["BIT-26JUN26-CDE", "BTC-USD"],
      ["ET-26JUN26-CDE", "ETH-USD"],
      ["NOL-19JUN26-CDE", "OIL-USD"],
      ["BTC", "BTC-USD"],
      ["ETH", "ETH-USD"],
      ["OIL", "OIL-USD"],
      ["BTC-USD", "BTC-USD"]
    ].each do |input, expected|
      it "maps #{input} to #{expected}" do
        expect(described_class.sentiment_symbol_for(input)).to eq(expected)
      end
    end

    it "returns nil for unknown identifiers" do
      expect(described_class.sentiment_symbol_for("DOGE-26JUN26-CDE")).to be_nil
    end
  end

  describe ".sentiment_symbols_for_enabled_contracts" do
    it "returns deduped sentiment symbols for enabled contracts" do
      create(:contract, product_id: "BIT-26JUN26-CDE", enabled: true)
      create(:contract, :ethereum, product_id: "ET-26JUN26-CDE", enabled: true)
      create(:contract, product_id: "NOL-19JUN26-CDE", base_currency: "OIL", enabled: true)
      create(:contract, product_id: "BIT-27JUL26-CDE", enabled: true)

      expect(described_class.sentiment_symbols_for_enabled_contracts).to match_array(
        %w[BTC-USD ETH-USD OIL-USD]
      )
    end

    it "excludes disabled contracts" do
      create(:contract, product_id: "BIT-26JUN26-CDE", enabled: false)

      expect(described_class.sentiment_symbols_for_enabled_contracts).to eq([])
    end
  end
end
