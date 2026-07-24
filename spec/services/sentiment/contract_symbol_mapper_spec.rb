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

  describe ".price_symbol_for" do
    it "uses the spot series when the sentiment symbol has its own 1h candles (BTC/ETH)" do
      create(:candle, symbol: "BTC-USD", timeframe: "1h", timestamp: 1.hour.ago)
      expect(described_class.price_symbol_for("BTC-USD")).to eq("BTC-USD")
    end

    it "picks the contract with the most 1h history when there is no spot series (OIL)" do
      create(:candle, symbol: "NOL-19AUG26-CDE", timeframe: "1h", timestamp: 3.hours.ago)
      create(:candle, symbol: "NOL-19AUG26-CDE", timeframe: "1h", timestamp: 2.hours.ago)
      create(:candle, symbol: "NOL-21SEP26-CDE", timeframe: "1h", timestamp: 1.hour.ago)

      expect(described_class.price_symbol_for("OIL-USD")).to eq("NOL-19AUG26-CDE")
    end

    it "returns nil when the symbol maps to no usable price series" do
      expect(described_class.price_symbol_for("DOGE-USD")).to be_nil
    end
  end
end
