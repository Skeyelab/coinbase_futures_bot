# frozen_string_literal: true

require "rails_helper"
require "json"

RSpec.describe MarketData::CoinbaseRest, type: :service do
  let(:product_id) { "BTC-USD" }
  let(:start_time) { 1.day.ago }
  let(:end_time) { Time.now.utc }

  before do
    @original_api_key = ENV["COINBASE_API_KEY"]
    @original_api_secret = ENV["COINBASE_API_SECRET"]
    ENV.delete("COINBASE_API_KEY")
    ENV.delete("COINBASE_API_SECRET")
  end

  after do
    ENV["COINBASE_API_KEY"] = @original_api_key if @original_api_key
    ENV["COINBASE_API_SECRET"] = @original_api_secret if @original_api_secret
  end

  describe "initialization" do
    it "initializes with default base url" do
      rest = described_class.new
      expect(rest.instance_variable_get(:@conn).url_prefix.to_s.chomp("/")).to eq("https://api.exchange.coinbase.com")
    end

    it "initializes with custom base url" do
      rest = described_class.new(base_url: "https://custom.api.com")
      expect(rest.instance_variable_get(:@conn).url_prefix.to_s.chomp("/")).to eq("https://custom.api.com")
    end

    it "initializes without api credentials" do
      rest = described_class.new
      expect(rest.instance_variable_get(:@authenticated)).to be(false)
    end

    it "initializes with api credentials" do
      ENV["COINBASE_API_KEY"] = "test_key"
      ENV["COINBASE_API_SECRET"] = "test_secret"
      rest = described_class.new
      expect(rest.instance_variable_get(:@authenticated)).to be(true)
      expect(rest.instance_variable_get(:@api_key)).to eq("test_key")
      expect(rest.instance_variable_get(:@api_secret)).to eq("test_secret")
    end
  end

  describe "API calls" do
    let(:rest) { described_class.new }

    it "list_products handles array response" do
      mock_response = instance_double("Response", body: [ { "id" => "BTC-USD", "status" => "online" } ].to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      products = rest.list_products
      expect(products.count).to eq(1)
      expect(products.first["id"]).to eq("BTC-USD")
    end

    it "list_products handles hash response" do
      mock_response = instance_double("Response", body: { "products" => [ { "id" => "BTC-USD", "status" => "online" } ] }.to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      products = rest.list_products
      expect(products.count).to eq(1)
      expect(products.first["id"]).to eq("BTC-USD")
    end

    it "fetch_candles handles array response" do
      mock_response = instance_double("Response", body: [ [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ] ].to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      candles = rest.fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)
      expect(candles.count).to eq(1)
      expect(candles.first[0]).to eq(1754930700)
      expect(candles.first[1]).to eq(119911.55)
    end

    it "fetch_candles handles hash response" do
      body = { "candles" => [ { "start" => "1754930700", "low" => 119911.55, "high" => 120177.23, "open" => 119968.18, "close" => 120069.34, "volume" => 23.20361858 } ] }
      mock_response = instance_double("Response", body: body.to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      candles = rest.fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)
      expect(candles.count).to eq(1)
      expect(candles.first[0]).to eq(1754930700)
      expect(candles.first[1]).to eq(119911.55)
    end

    it "fetch_candles handles error response" do
      mock_response = instance_double("Response", body: { "error" => "Invalid product" }.to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      expect do
        rest.fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)
      end.to raise_error(RuntimeError, "API Error: Invalid product")
    end

    it "fetch_candles passes parameters" do
      mock_response = instance_double("Response", body: [].to_json)
      conn = rest.instance_variable_get(:@conn)
      expect(conn).to receive(:get).and_return(mock_response)
      rest.fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 1800)
    end

    it "upsert_1h_candles creates candles" do
      mock_candles = [
        [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ],
        [ 1754934300, 120069.34, 120200.00, 120000.00, 120150.00, 45.12345678 ]
      ]

      allow(rest).to receive(:fetch_candles).and_return(mock_candles)
      expect {
        rest.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
      }.to change { Candle.count }.by(2)

      candle = Candle.find_by(symbol: product_id, timeframe: "1h")
      expect(candle.symbol).to eq("BTC-USD")
      expect(candle.timeframe).to eq("1h")
      expect(candle.open).to eq(BigDecimal("119968.18"))
      expect(candle.high).to eq(BigDecimal("120177.23"))
      expect(candle.low).to eq(BigDecimal("119911.55"))
      expect(candle.close).to eq(BigDecimal("120069.34"))
      expect(candle.volume).to eq(BigDecimal("23.20361858"))
    end

    it "upsert_30m_candles creates 15m candles" do
      mock_candles = [ [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ] ]
      allow(rest).to receive(:fetch_candles).and_return(mock_candles)
      expect {
        rest.upsert_30m_candles(product_id: product_id, start_time: start_time, end_time: end_time)
      }.to change { Candle.count }.by(1)
      candle = Candle.find_by(symbol: product_id, timeframe: "15m")
      expect(candle.timeframe).to eq("15m")
    end

    it "upsert_30m_candles uses chunked fetching for large ranges" do
      large_start = 10.days.ago
      large_end = Time.now.utc
      expect_any_instance_of(described_class).not_to receive(:upsert_30m_candles_chunked) # sanity default
      expect(rest).to receive(:upsert_30m_candles_chunked).with(product_id: product_id, start_time: large_start, end_time: large_end)
      rest.upsert_30m_candles(product_id: product_id, start_time: large_start, end_time: large_end)
    end

    it "upsert_1h_candles uses chunked fetching for large ranges" do
      large_start = 10.days.ago
      large_end = Time.now.utc
      expect(rest).to receive(:upsert_1h_candles_chunked).with(product_id: product_id, start_time: large_start, end_time: large_end)
      rest.upsert_1h_candles(product_id: product_id, start_time: large_start, end_time: large_end)
    end

    it "create_default_futures_products creates products" do
      rest = described_class.new
      expect {
        rest.create_default_futures_products
      }.to change { TradingPair.count }.by(2)
      btc_perp = TradingPair.find_by(product_id: "BTC-USD-PERP")
      eth_perp = TradingPair.find_by(product_id: "ETH-USD-PERP")
      expect(btc_perp).not_to be_nil
      expect(eth_perp).not_to be_nil
      expect(btc_perp.base_currency).to eq("BTC")
      expect(eth_perp.base_currency).to eq("ETH")
      expect(btc_perp.quote_currency).to eq("USD")
      expect(btc_perp.status).to eq("online")
    end
  end
end