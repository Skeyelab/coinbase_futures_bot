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

    def oil_contract(product_id)
      Contract.find_or_create_by!(product_id: product_id) do |c|
        c.base_currency = "OIL"
        c.quote_currency = "USD"
        c.status = "active"
        c.enabled = true
        c.expiration_date = Date.current + 30
      end
    end

    it "picks the contract with the most 1h history when there is no spot series (OIL)" do
      oil_contract("NOL-19AUG26-CDE")
      oil_contract("NOL-21SEP26-CDE")
      create(:candle, symbol: "NOL-19AUG26-CDE", timeframe: "1h", timestamp: 3.hours.ago)
      create(:candle, symbol: "NOL-19AUG26-CDE", timeframe: "1h", timestamp: 2.hours.ago)
      create(:candle, symbol: "NOL-21SEP26-CDE", timeframe: "1h", timestamp: 1.hour.ago)

      expect(described_class.price_symbol_for("OIL-USD")).to eq("NOL-19AUG26-CDE")
    end

    # The point of the change. Matching candles by "symbol LIKE 'NOL%'" could
    # not use the (symbol, timeframe, timestamp) index under the default
    # collation, so it seq-scanned 3.2M rows in 973ms, 1,163 times a day. That
    # single query was both the top Sentry slow-query event and the source of
    # the NoMethodError storm.
    it "resolves the price series without a prefix scan over every candle" do
      oil_contract("NOL-19AUG26-CDE")
      create(:candle, symbol: "NOL-19AUG26-CDE", timeframe: "1h", timestamp: 1.hour.ago)

      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      begin
        described_class.price_symbol_for("OIL-USD")
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(statements.select { |sql| sql.include?("LIKE") }).to be_empty
    end

    # Behaviour change, recorded deliberately. Candles whose Contract row is
    # gone are no longer eligible. Production has no such orphans (all four NOL
    # candle symbols have Contract rows), expired contracts are disabled rather
    # than deleted, and an untracked contract has no business being the price
    # series we measure predictiveness against.
    it "ignores candles that no longer have a contract" do
      create(:candle, symbol: "NOL-19OCT26-CDE", timeframe: "1h", timestamp: 1.hour.ago)

      expect(described_class.price_symbol_for("OIL-USD")).to be_nil
    end

    def sql_for(&block)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      begin
        block.call
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      statements
    end

    # These guards are short-circuits, not correctness checks -- the queries
    # they skip would return nothing anyway. Since the whole point of this
    # change is doing less database work, the skipping itself is the behaviour
    # worth pinning.
    it "does not look up contracts for an underlying it does not track" do
      statements = sql_for { described_class.price_symbol_for("DOGE-USD") }

      expect(statements.select { |sql| sql.include?("contracts") }).to be_empty
    end

    it "does not query candles when the underlying has no contracts at all" do
      statements = sql_for { described_class.price_symbol_for("OIL-USD") }

      expect(statements.select { |sql| sql.include?("GROUP BY") }).to be_empty
    end

    it "still considers a contract that has been disabled" do
      oil_contract("NOL-20JUL26-CDE").update!(enabled: false)
      create(:candle, symbol: "NOL-20JUL26-CDE", timeframe: "1h", timestamp: 1.hour.ago)

      expect(described_class.price_symbol_for("OIL-USD")).to eq("NOL-20JUL26-CDE")
    end

    it "returns nil when the symbol maps to no usable price series" do
      expect(described_class.price_symbol_for("DOGE-USD")).to be_nil
    end
  end
end
