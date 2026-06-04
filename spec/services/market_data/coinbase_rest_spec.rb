# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::CoinbaseRest, type: :service do
  let(:service) { described_class.new }
  let(:base_url) { "https://api.exchange.coinbase.com" }
  let(:custom_url) { "https://api-sandbox.exchange.coinbase.com" }

  # Mock Faraday connection
  let(:mock_connection) { instance_double(Faraday::Connection) }
  let(:mock_response) { instance_double(Faraday::Response) }

  before do
    # Mock the Faraday connection
    allow(Faraday).to receive(:new).and_return(mock_connection)
    allow(mock_connection).to receive(:headers).and_return({})
    allow(mock_connection).to receive(:get).and_return(mock_response)
    allow(mock_response).to receive(:body).and_return('{"test": "data"}')
  end

  describe "#initialize" do
    context "with default URL" do
      it "initializes with default Coinbase API URL" do
        expect(Faraday).to receive(:new).with(described_class::DEFAULT_BASE)
        described_class.new
      end
    end

    context "with custom URL" do
      it "initializes with custom URL from environment" do
        allow(ENV).to receive(:fetch).with("COINBASE_REST_URL", anything).and_return(custom_url)
        expect(Faraday).to receive(:new).with(custom_url)
        described_class.new
      end
    end

    context "with API credentials" do
      let(:api_key) { "test_api_key" }
      let(:api_secret) { "test_api_secret" }

      before do
        allow(ENV).to receive(:[]).with("COINBASE_API_KEY").and_return(api_key)
        allow(ENV).to receive(:[]).with("COINBASE_API_SECRET").and_return(api_secret)
      end

      it "sets up authenticated connection" do
        service = described_class.new
        expect(service.instance_variable_get(:@authenticated)).to be true
        expect(service.instance_variable_get(:@api_key)).to eq(api_key)
        expect(service.instance_variable_get(:@api_secret)).to eq(api_secret)
      end
    end

    context "without API credentials" do
      before do
        allow(ENV).to receive(:[]).with("COINBASE_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("COINBASE_API_SECRET").and_return(nil)
        allow(Rails.logger).to receive(:warn)
      end

      it "sets up unauthenticated connection and logs warning" do
        expect(Rails.logger).to receive(:warn).with(/Coinbase API credentials not fully configured/)
        service = described_class.new
        expect(service.instance_variable_get(:@authenticated)).to be false
      end
    end
  end

  describe "#list_products" do
    let(:products_data) { [{"product_id" => "BIT-29DEC24-CDE", "trading_disabled" => false}] }
    let(:api_response) { {"products" => products_data, "pagination" => {"has_next" => false}} }

    before do
      allow(service).to receive(:authenticated_get).and_return(mock_response)
      allow(mock_response).to receive(:body).and_return(api_response.to_json)
      allow(Rails.logger).to receive(:info)
    end

    it "calls Advanced Trade API products endpoint with EXPIRING server-side filters" do
      service.list_products
      expect(service).to have_received(:authenticated_get)
        .with("/api/v3/brokerage/products", hash_including(
          product_type: "FUTURE",
          contract_expiry_type: "EXPIRING",
          expiring_contract_status: "STATUS_UNEXPIRED"
        ))
    end

    it "returns products array from hash response" do
      result = service.list_products
      expect(result).to eq(products_data)
    end

    it "logs the number of products fetched" do
      expect(Rails.logger).to receive(:info).with("Fetched 1 products from Advanced Trade API")
      service.list_products
    end

    it "returns empty array when products key missing" do
      allow(mock_response).to receive(:body).and_return({"pagination" => {"has_next" => false}}.to_json)
      result = service.list_products
      expect(result).to eq([])
    end

    it "paginates through all pages when has_next is true" do
      page1_resp = instance_double(Faraday::Response)
      page2_resp = instance_double(Faraday::Response)
      page1_body = {"products" => [{"product_id" => "BIT-29DEC24-CDE"}], "pagination" => {"has_next" => true, "next_cursor" => "cursor_abc"}}.to_json
      page2_body = {"products" => [{"product_id" => "ET-29DEC24-CDE"}], "pagination" => {"has_next" => false}}.to_json

      allow(page1_resp).to receive(:body).and_return(page1_body)
      allow(page2_resp).to receive(:body).and_return(page2_body)

      call_count = 0
      allow(service).to receive(:authenticated_get) do |_path, params|
        call_count += 1
        (call_count == 1) ? page1_resp : page2_resp
      end

      result = service.list_products
      expect(result.map { |p| p["product_id"] }).to eq(["BIT-29DEC24-CDE", "ET-29DEC24-CDE"])
      expect(service).to have_received(:authenticated_get).twice
    end
  end

  describe "#upsert_products" do
    let(:futures_products) do
      [
        {
          "product_id" => "BIT-29DEC24-CDE",
          "trading_disabled" => false,
          "base_min_size" => "0.0001",
          "base_increment" => "0.0001",
          "quote_increment" => "0.01"
        }
      ]
    end

    before do
      allow(service).to receive(:list_products).and_return(futures_products)
      allow(TradingPair).to receive(:parse_contract_info).and_return({
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2024, 12, 29),
        contract_type: "CDE"
      })
      allow(TradingPair).to receive(:upsert)
      allow(Rails.logger).to receive(:info)
    end

    it "calls list_products" do
      service.upsert_products
      expect(service).to have_received(:list_products)
    end

    it "parses contract info for futures products" do
      service.upsert_products
      expect(TradingPair).to have_received(:parse_contract_info).with("BIT-29DEC24-CDE")
    end

    it "upserts trading pairs with correct data" do
      expected_upsert_data = {
        product_id: "BIT-29DEC24-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2024, 12, 29),
        contract_type: "CDE",
        status: "active",
        min_size: "0.0001",
        price_increment: "0.01",
        size_increment: "0.0001",
        enabled: true,
        created_at: anything,
        updated_at: anything
      }

      service.upsert_products
      expect(TradingPair).to have_received(:upsert).with(
        hash_including(expected_upsert_data),
        unique_by: :index_trading_pairs_on_product_id
      )
    end

    it "prefers contract_expiry from future_product_details over product_id date parsing" do
      product_with_details = futures_products.first.merge(
        "future_product_details" => {"contract_expiry" => "2025-01-10T16:00:00Z"}
      )
      allow(service).to receive(:list_products).and_return([product_with_details])

      service.upsert_products
      expect(TradingPair).to have_received(:upsert).with(
        hash_including(expiration_date: Date.new(2025, 1, 10)),
        anything
      )
    end

    it "includes NOL- futures products" do
      nol_product = {
        "product_id" => "NOL-19JUN26-CDE",
        "trading_disabled" => false,
        "base_min_size" => "1",
        "base_increment" => "1",
        "quote_increment" => "0.01"
      }
      allow(service).to receive(:list_products).and_return([nol_product])
      allow(TradingPair).to receive(:parse_contract_info).with("NOL-19JUN26-CDE").and_return({
        base_currency: "NOL",
        quote_currency: "USD",
        expiration_date: Date.new(2026, 6, 19),
        contract_type: "CDE"
      })

      service.upsert_products
      expect(TradingPair).to have_received(:upsert).with(
        hash_including(product_id: "NOL-19JUN26-CDE"),
        anything
      )
    end

    it "logs the number of upserted products" do
      expect(Rails.logger).to receive(:info).with("Upserted 1 futures products")
      service.upsert_products
    end

    it "includes NOL (oil) futures products in filter" do
      nol_products = [
        {
          "product_id" => "NOL-19JUN26-CDE",
          "status" => "online",
          "quote_currency" => "USD",
          "base_increment" => "0.01",
          "quote_increment" => "0.01"
        }
      ]
      allow(service).to receive(:list_products).and_return(nol_products)
      allow(TradingPair).to receive(:parse_contract_info).and_return({
        base_currency: "OIL",
        quote_currency: "USD",
        expiration_date: Date.new(2026, 6, 19),
        contract_type: "CDE"
      })
      service.upsert_products
      expect(TradingPair).to have_received(:parse_contract_info).with("NOL-19JUN26-CDE")
    end
  end

  describe "#fetch_candles" do
    let(:product_id) { "BIT-29DEC24-CDE" }
    let(:start_time) { "2022-01-01T00:00:00Z" }
    let(:end_time) { "2022-01-02T00:00:00Z" }
    let(:hash_response) do
      {
        "candles" => [
          {
            "start" => "1640995200",
            "low" => "50000",
            "high" => "51000",
            "open" => "49500",
            "close" => "50500",
            "volume" => "100"
          }
        ]
      }
    end

    before do
      allow(service).to receive(:authenticated_get).and_return(mock_response)
      allow(mock_response).to receive(:body).and_return(hash_response.to_json)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    context "with basic parameters" do
      it "calls Advanced Trade API candles endpoint" do
        service.fetch_candles(product_id: product_id)
        expect(service).to have_received(:authenticated_get).with(
          "/api/v3/brokerage/products/#{product_id}/candles",
          hash_including(granularity: "ONE_HOUR")
        )
      end

      it "returns candle data as array of arrays" do
        result = service.fetch_candles(product_id: product_id)
        expect(result).to eq([[1_640_995_200, "50000", "51000", "49500", "50500", "100"]])
      end
    end

    context "with time parameters" do
      it "converts ISO8601 times to unix timestamps in request" do
        service.fetch_candles(
          product_id: product_id,
          start_iso8601: start_time,
          end_iso8601: end_time
        )

        expect(service).to have_received(:authenticated_get).with(
          anything,
          hash_including(start: anything, end: anything)
        )
      end
    end

    context "with custom granularity" do
      it "maps seconds to granularity string" do
        service.fetch_candles(product_id: product_id, granularity: 900)
        expect(service).to have_received(:authenticated_get).with(
          anything,
          hash_including(granularity: "FIFTEEN_MINUTE")
        )
      end
    end

    context "with hash response containing candles" do
      let(:hash_response) do
        {
          "candles" => [
            {
              "start" => "1640995200",
              "low" => "50000",
              "high" => "51000",
              "open" => "49500",
              "close" => "50500",
              "volume" => "100"
            }
          ]
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(hash_response.to_json)
      end

      it "converts hash format to array format" do
        result = service.fetch_candles(product_id: product_id)
        # API returns string values for numeric fields
        expected_data = [[1_640_995_200, "50000", "51000", "49500", "50500", "100"]]
        expect(result).to eq(expected_data)
      end
    end

    context "with error response" do
      let(:error_response) { {"error" => "Invalid product"} }

      before do
        allow(mock_response).to receive(:body).and_return(error_response.to_json)
        allow(Rails.logger).to receive(:error)
      end

      it "raises error with message" do
        expect(Rails.logger).to receive(:error).with("Candles API error: Invalid product")
        expect do
          service.fetch_candles(product_id: product_id)
        end.to raise_error("API Error: Invalid product")
      end
    end
  end

  describe "#authenticated_get" do
    let(:path) { "/test/path" }
    let(:params) { {test: "value"} }

    before do
      allow(service).to receive(:authenticated_get).and_call_original
    end

    it "sets Authorization Bearer header and makes GET request" do
      allow(JWT).to receive(:encode).and_return("test.jwt.token")
      allow(OpenSSL::PKey).to receive(:read).and_return(double("pkey"))

      service.send(:authenticated_get, path, params)

      expect(mock_connection.headers["Authorization"]).to eq("Bearer test.jwt.token")
      expect(mock_connection).to have_received(:get).with(path, params)
    end

    it "uses ES256 JWT encoding" do
      pkey = double("pkey")
      allow(OpenSSL::PKey).to receive(:read).and_return(pkey)
      expect(JWT).to receive(:encode).with(
        hash_including(sub: anything, iss: "cdp", uri: "GET api.coinbase.com#{path}"),
        pkey,
        "ES256",
        anything
      ).and_return("test.jwt.token")

      service.send(:authenticated_get, path)
    end
  end

  describe "#upsert_1h_candles" do
    let(:product_id) { "BTC-USD" }
    let(:start_time) { 1.day.ago }
    let(:end_time) { Time.now }
    let(:candle_data) { [[1_640_995_200, 50_000, 51_000, 49_500, 50_500, 100]] }

    before do
      allow(service).to receive(:fetch_candles).and_return(candle_data)
      allow(Candle).to receive(:create_or_find_by)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it "fetches candles with correct parameters" do
      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)

      expect(service).to have_received(:fetch_candles).with(
        product_id: product_id,
        start_iso8601: start_time.iso8601,
        end_iso8601: end_time.iso8601,
        granularity: 3600
      )
    end

    it "creates candles in database" do
      expect(Candle).to receive(:create_or_find_by).with(
        symbol: product_id,
        timeframe: "1h",
        timestamp: Time.at(1_640_995_200).utc
      )

      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
    end

    it "logs completion" do
      expect(Rails.logger).to receive(:info).with("Completed upserting 1h candles for BTC-USD")
      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
    end

    context "with large date range" do
      let(:large_range_start) { 10.days.ago }
      let(:large_range_end) { Time.now }

      before do
        allow(service).to receive(:upsert_1h_candles_chunked)
      end

      it "uses chunked fetching for large ranges" do
        service.upsert_1h_candles(product_id: product_id, start_time: large_range_start, end_time: large_range_end)
        expect(service).to have_received(:upsert_1h_candles_chunked).with(
          product_id: product_id,
          start_time: large_range_start,
          end_time: large_range_end
        )
      end

      it "does not fetch directly for large ranges" do
        service.upsert_1h_candles(product_id: product_id, start_time: large_range_start, end_time: large_range_end)
        expect(service).not_to have_received(:fetch_candles)
      end
    end

    # TODO: Add test for invalid data format handling after fixing logging bug in service
  end

  describe "#fetch_candles_in_chunks" do
    let(:product_id) { "BTC-USD" }
    let(:start_time) { 30.days.ago }
    let(:end_time) { Time.now }
    let(:chunk_data) { [[1_640_995_200, 50_000, 51_000, 49_500, 50_500, 100]] }

    before do
      allow(service).to receive(:fetch_candles).and_return(chunk_data)
      allow(service).to receive(:sleep)
    end

    it "fetches data in chunks" do
      expect(service).to receive(:fetch_candles).exactly(2).times

      service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )
    end

    it "returns concatenated data from all chunks" do
      result = service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )

      expect(result).to eq(chunk_data + chunk_data)
    end

    it "adds delay between chunks" do
      expect(service).to receive(:sleep).with(0.1).twice

      service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )
    end

    context "with error in chunk" do
      before do
        call_count = 0
        allow(service).to receive(:fetch_candles) do
          call_count += 1
          (call_count == 2) ? raise(StandardError.new("API Error")) : chunk_data
        end
      end

      it "continues processing other chunks" do
        expect(Rails.logger).to receive(:error).with(/Failed to fetch candles chunk/)

        result = service.fetch_candles_in_chunks(
          product_id: product_id,
          start_time: start_time,
          end_time: end_time,
          chunk_days: 20
        )

        expect(result).to eq(chunk_data) # Only first chunk data
      end
    end
  end

  describe "private methods" do
    describe "#update_all_contracts" do
      let(:mock_manager) { instance_double(MarketData::FuturesContractManager) }

      before do
        allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_manager)
        allow(mock_manager).to receive(:update_all_contracts)
      end

      it "creates FuturesContractManager and calls update_all_contracts" do
        service.send(:update_all_contracts)
        expect(MarketData::FuturesContractManager).to have_received(:new)
        expect(mock_manager).to have_received(:update_all_contracts)
      end
    end

    describe "#update_current_month_contracts" do
      let(:mock_manager) { instance_double(MarketData::FuturesContractManager) }

      before do
        allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_manager)
        allow(mock_manager).to receive(:update_current_month_contracts)
      end

      it "creates FuturesContractManager and calls update_current_month_contracts" do
        service.send(:update_current_month_contracts)
        expect(MarketData::FuturesContractManager).to have_received(:new)
        expect(mock_manager).to have_received(:update_current_month_contracts)
      end
    end
  end
end
