# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketData::CoinbaseRest, type: :service do
  let(:service) { described_class.new }
  let(:base_url) { 'https://api.exchange.coinbase.com' }
  let(:custom_url) { 'https://api-sandbox.exchange.coinbase.com' }

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

  describe '#initialize' do
    context 'with default URL' do
      it 'initializes with default Coinbase API URL' do
        expect(Faraday).to receive(:new).with(described_class::DEFAULT_BASE)
        described_class.new
      end
    end

    context 'with custom URL' do
      it 'initializes with custom URL from environment' do
        allow(ENV).to receive(:fetch).with('COINBASE_REST_URL', anything).and_return(custom_url)
        expect(Faraday).to receive(:new).with(custom_url)
        described_class.new
      end
    end

    context 'with API credentials' do
      let(:api_key) { 'test_api_key' }
      let(:api_secret) { 'test_api_secret' }

      before do
        allow(ENV).to receive(:[]).with('COINBASE_API_KEY').and_return(api_key)
        allow(ENV).to receive(:[]).with('COINBASE_API_SECRET').and_return(api_secret)
      end

      it 'sets up authenticated connection' do
        service = described_class.new
        expect(service.instance_variable_get(:@authenticated)).to be true
        expect(service.instance_variable_get(:@api_key)).to eq(api_key)
        expect(service.instance_variable_get(:@api_secret)).to eq(api_secret)
      end
    end

    context 'without API credentials' do
      before do
        allow(ENV).to receive(:[]).with('COINBASE_API_KEY').and_return(nil)
        allow(ENV).to receive(:[]).with('COINBASE_API_SECRET').and_return(nil)
        allow(Rails.logger).to receive(:warn)
      end

      it 'sets up unauthenticated connection and logs warning' do
        expect(Rails.logger).to receive(:warn).with(/Coinbase API credentials not fully configured/)
        service = described_class.new
        expect(service.instance_variable_get(:@authenticated)).to be false
      end
    end
  end

  describe '#list_products' do
    let(:products_data) { [{ 'id' => 'BTC-USD', 'status' => 'online', 'quote_currency' => 'USD' }] }

    before do
      allow(mock_response).to receive(:body).and_return(products_data.to_json)
      allow(Rails.logger).to receive(:info)
    end

    context 'with array response' do
      it 'returns products array' do
        result = service.list_products
        expect(result).to eq(products_data)
      end

      it 'logs the number of products fetched' do
        expect(Rails.logger).to receive(:info).with('Fetched 1 products from Exchange API')
        service.list_products
      end

      it 'logs sample product' do
        expect(Rails.logger).to receive(:info).with(/Sample product/)
        service.list_products
      end
    end

    context 'with hash response containing products key' do
      let(:hash_response) { { 'products' => products_data } }

      before do
        allow(mock_response).to receive(:body).and_return(hash_response.to_json)
      end

      it 'extracts products from hash' do
        result = service.list_products
        expect(result).to eq(products_data)
      end
    end

    context 'with non-array response' do
      let(:single_product) { { 'id' => 'BTC-USD', 'status' => 'online', 'quote_currency' => 'USD' } }

      before do
        allow(mock_response).to receive(:body).and_return(single_product.to_json)
      end

      it 'wraps single product in array' do
        result = service.list_products
        expect(result).to eq([single_product])
      end
    end
  end

  describe '#upsert_products' do
    let(:futures_products) do
      [
        {
          'id' => 'BIT-29DEC24-CDE',
          'status' => 'online',
          'quote_currency' => 'USD',
          'base_increment' => '0.0001',
          'quote_increment' => '0.01'
        }
      ]
    end

    before do
      allow(service).to receive(:list_products).and_return(futures_products)
      allow(TradingPair).to receive(:parse_contract_info).and_return({
                                                                       base_currency: 'BIT',
                                                                       quote_currency: 'USD',
                                                                       expiration_date: Date.new(2024, 12, 29),
                                                                       contract_type: 'future'
                                                                     })
      allow(TradingPair).to receive(:upsert)
      allow(service).to receive(:update_all_contracts)
      allow(Rails.logger).to receive(:info)
    end

    it 'filters for online USD futures products' do
      service.upsert_products
      expect(service).to have_received(:list_products)
    end

    it 'parses contract info for futures products' do
      service.upsert_products
      expect(TradingPair).to have_received(:parse_contract_info).with('BIT-29DEC24-CDE')
    end

    it 'upserts trading pairs with correct data' do
      expected_upsert_data = {
        product_id: 'BIT-29DEC24-CDE',
        base_currency: 'BIT',
        quote_currency: 'USD',
        expiration_date: Date.new(2024, 12, 29),
        contract_type: 'future',
        status: 'online',
        min_size: '0.0001',
        price_increment: '0.01',
        size_increment: '0.0001',
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

    it 'updates all contracts' do
      service.upsert_products
      expect(service).to have_received(:update_all_contracts)
    end

    it 'logs the number of upserted products' do
      expect(Rails.logger).to receive(:info).with('Upserted 1 futures products')
      service.upsert_products
    end
  end

  describe '#fetch_candles' do
    let(:product_id) { 'BTC-USD' }
    let(:candle_data) { [[1_640_995_200, 50_000, 51_000, 49_500, 50_500, 100]] }
    let(:start_time) { '2022-01-01T00:00:00Z' }
    let(:end_time) { '2022-01-02T00:00:00Z' }

    before do
      allow(mock_response).to receive(:body).and_return(candle_data.to_json)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    context 'with basic parameters' do
      it 'makes GET request with correct path' do
        service.fetch_candles(product_id: product_id)
        expect(mock_connection).to have_received(:get).with("/products/#{product_id}/candles",
                                                            hash_including(granularity: 3600))
      end

      it 'returns candle data as array' do
        result = service.fetch_candles(product_id: product_id)
        expect(result).to eq(candle_data)
      end
    end

    context 'with time parameters' do
      it 'includes start and end times in request' do
        service.fetch_candles(
          product_id: product_id,
          start_iso8601: start_time,
          end_iso8601: end_time
        )

        expect(mock_connection).to have_received(:get).with(
          "/products/#{product_id}/candles",
          hash_including(start: start_time, end: end_time, granularity: 3600)
        )
      end
    end

    context 'with custom granularity' do
      it 'uses specified granularity' do
        service.fetch_candles(product_id: product_id, granularity: 900)
        expect(mock_connection).to have_received(:get).with(
          "/products/#{product_id}/candles",
          hash_including(granularity: 900)
        )
      end
    end

    context 'with authentication' do
      let(:service) do
        allow(ENV).to receive(:[]).with('COINBASE_API_KEY').and_return('test_key')
        allow(ENV).to receive(:[]).with('COINBASE_API_SECRET').and_return('test_secret')
        described_class.new
      end

      it 'uses authenticated request' do
        allow(service).to receive(:authenticated_get).and_return(mock_response)
        service.fetch_candles(product_id: product_id)
        expect(service).to have_received(:authenticated_get).with("/products/#{product_id}/candles", anything)
      end
    end

    context 'with hash response containing candles' do
      let(:hash_response) do
        {
          'candles' => [
            {
              'start' => '1640995200',
              'low' => '50000',
              'high' => '51000',
              'open' => '49500',
              'close' => '50500',
              'volume' => '100'
            }
          ]
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(hash_response.to_json)
      end

      it 'converts hash format to array format' do
        result = service.fetch_candles(product_id: product_id)
        # API returns string values for numeric fields
        expected_data = [[1_640_995_200, '50000', '51000', '49500', '50500', '100']]
        expect(result).to eq(expected_data)
      end
    end

    context 'with error response' do
      let(:error_response) { { 'error' => 'Invalid product' } }

      before do
        allow(mock_response).to receive(:body).and_return(error_response.to_json)
        allow(Rails.logger).to receive(:error)
      end

      it 'raises error with message' do
        expect(Rails.logger).to receive(:error).with('API Error: Invalid product')
        expect do
          service.fetch_candles(product_id: product_id)
        end.to raise_error('API Error: Invalid product')
      end
    end
  end

  describe '#authenticated_get' do
    let(:path) { '/test/path' }
    let(:params) { { test: 'value' } }
    let(:service) do
      allow(ENV).to receive(:[]).with('COINBASE_API_KEY').and_return('test_key')
      allow(ENV).to receive(:[]).with('COINBASE_API_SECRET').and_return('test_secret')
      described_class.new
    end

    before do
      allow(Time).to receive(:now).and_return(Time.at(1_640_995_200)) # Fixed timestamp for testing
      allow(OpenSSL::HMAC).to receive(:hexdigest).and_return('test_signature')
    end

    it 'sets authentication headers' do
      service.send(:authenticated_get, path, params)

      expect(mock_connection.headers['CB-ACCESS-KEY']).to eq('test_key')
      expect(mock_connection.headers['CB-ACCESS-SIGN']).to eq('test_signature')
      expect(mock_connection.headers['CB-ACCESS-TIMESTAMP']).to eq('1640995200')
    end

    it 'makes authenticated GET request' do
      service.send(:authenticated_get, path, params)
      expect(mock_connection).to have_received(:get).with(path, params)
    end

    it 'creates correct prehash string' do
      expected_prehash = '1640995200GET/test/path?test=value'
      expect(OpenSSL::HMAC).to receive(:hexdigest).with(
        OpenSSL::Digest.new('sha256'),
        'test_secret',
        expected_prehash
      )

      service.send(:authenticated_get, path, params)
    end

    context 'without parameters' do
      it 'creates prehash string without query parameters' do
        expected_prehash = '1640995200GET/test/path'
        expect(OpenSSL::HMAC).to receive(:hexdigest).with(
          anything,
          'test_secret',
          expected_prehash
        )

        service.send(:authenticated_get, path)
      end
    end
  end

  describe '#upsert_1h_candles' do
    let(:product_id) { 'BTC-USD' }
    let(:start_time) { 1.day.ago }
    let(:end_time) { Time.now }
    let(:candle_data) { [[1_640_995_200, 50_000, 51_000, 49_500, 50_500, 100]] }

    before do
      allow(service).to receive(:fetch_candles).and_return(candle_data)
      allow(Candle).to receive(:create_or_find_by)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it 'fetches candles with correct parameters' do
      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)

      expect(service).to have_received(:fetch_candles).with(
        product_id: product_id,
        start_iso8601: start_time.iso8601,
        end_iso8601: end_time.iso8601,
        granularity: 3600
      )
    end

    it 'creates candles in database' do
      expect(Candle).to receive(:create_or_find_by).with(
        symbol: product_id,
        timeframe: '1h',
        timestamp: Time.at(1_640_995_200).utc
      )

      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
    end

    it 'logs completion' do
      expect(Rails.logger).to receive(:info).with('Completed upserting 1h candles for BTC-USD')
      service.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
    end

    context 'with large date range' do
      let(:large_range_start) { 10.days.ago }
      let(:large_range_end) { Time.now }

      before do
        allow(service).to receive(:upsert_1h_candles_chunked)
      end

      it 'uses chunked fetching for large ranges' do
        service.upsert_1h_candles(product_id: product_id, start_time: large_range_start, end_time: large_range_end)
        expect(service).to have_received(:upsert_1h_candles_chunked).with(
          product_id: product_id,
          start_time: large_range_start,
          end_time: large_range_end
        )
      end

      it 'does not fetch directly for large ranges' do
        service.upsert_1h_candles(product_id: product_id, start_time: large_range_start, end_time: large_range_end)
        expect(service).not_to have_received(:fetch_candles)
      end
    end

    # TODO: Add test for invalid data format handling after fixing logging bug in service
  end

  describe '#fetch_candles_in_chunks' do
    let(:product_id) { 'BTC-USD' }
    let(:start_time) { 30.days.ago }
    let(:end_time) { Time.now }
    let(:chunk_data) { [[1_640_995_200, 50_000, 51_000, 49_500, 50_500, 100]] }

    before do
      allow(service).to receive(:fetch_candles).and_return(chunk_data)
      allow(service).to receive(:sleep)
    end

    it 'fetches data in chunks' do
      expect(service).to receive(:fetch_candles).exactly(2).times

      service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )
    end

    it 'returns concatenated data from all chunks' do
      result = service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )

      expect(result).to eq(chunk_data + chunk_data)
    end

    it 'adds delay between chunks' do
      expect(service).to receive(:sleep).with(0.1).twice

      service.fetch_candles_in_chunks(
        product_id: product_id,
        start_time: start_time,
        end_time: end_time,
        chunk_days: 20
      )
    end

    context 'with error in chunk' do
      before do
        call_count = 0
        allow(service).to receive(:fetch_candles) do
          call_count += 1
          call_count == 2 ? raise(StandardError.new('API Error')) : chunk_data
        end
      end

      it 'continues processing other chunks' do
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

  describe 'private methods' do
    describe '#update_all_contracts' do
      let(:mock_manager) { instance_double(MarketData::FuturesContractManager) }

      before do
        allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_manager)
        allow(mock_manager).to receive(:update_all_contracts)
      end

      it 'creates FuturesContractManager and calls update_all_contracts' do
        service.send(:update_all_contracts)
        expect(MarketData::FuturesContractManager).to have_received(:new)
        expect(mock_manager).to have_received(:update_all_contracts)
      end
    end

    describe '#update_current_month_contracts' do
      let(:mock_manager) { instance_double(MarketData::FuturesContractManager) }

      before do
        allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_manager)
        allow(mock_manager).to receive(:update_current_month_contracts)
      end

      it 'creates FuturesContractManager and calls update_current_month_contracts' do
        service.send(:update_current_month_contracts)
        expect(MarketData::FuturesContractManager).to have_received(:new)
        expect(mock_manager).to have_received(:update_current_month_contracts)
      end
    end
  end
end
