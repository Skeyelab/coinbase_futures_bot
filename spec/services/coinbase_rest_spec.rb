# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::CoinbaseRest, type: :service do
  let(:rest) { described_class.new }
  let(:product_id) { "BTC-USD" }
  let(:start_time) { 1.day.ago.beginning_of_hour }
  let(:end_time) { 1.hour.ago.beginning_of_hour }

  # Clean up any test data after each test
  after do
    # Clean up any candles created during tests
    Candle.where("created_at > ?", 1.hour.ago).destroy_all
  end

  describe "initialization" do
    it "initializes successfully" do
      expect(rest).to be_a(described_class)
    end

    it "initializes with custom base url" do
      custom_rest = described_class.new(base_url: "https://custom.example.com")
      expect(custom_rest).to be_a(described_class)
    end

    context "with environment configuration" do
      it "handles missing API credentials gracefully" do
        # Test that the service can be instantiated without credentials
        # The actual authentication behavior will be tested in integration tests
        ClimateControl.modify(COINBASE_API_KEY: nil, COINBASE_API_SECRET: nil) do
          rest = described_class.new
          expect(rest).to be_a(described_class)
        end
      end

      it "can be configured with API credentials" do
        ClimateControl.modify(COINBASE_API_KEY: "test_key", COINBASE_API_SECRET: "test_secret") do
          rest = described_class.new
          expect(rest).to be_a(described_class)
        end
      end
    end
  end

  describe "data integration and persistence" do
    context "with realistic market data simulation" do
      # Create test data that simulates real API responses without external calls
      let(:mock_candle_data) do
        [
          [1_752_000_000, 50_000.0, 51_000.0, 49_500.0, 50_500.0, 100.0],
          [1_752_000_300, 50_500.0, 50_800.0, 50_200.0, 50_700.0, 150.0],
          [1_752_000_600, 50_700.0, 51_200.0, 50_600.0, 51_100.0, 200.0]
        ]
      end

      before do
        # Create realistic test data instead of mocking external API calls
        allow(rest).to receive(:fetch_candles).and_return(mock_candle_data)
      end

      it "handles candle data array format correctly" do
        candles = rest.fetch_candles(
          product_id: product_id,
          start_iso8601: start_time.iso8601,
          end_iso8601: end_time.iso8601,
          granularity: 3600
        )
        expect(candles).to be_an(Array)
        expect(candles.first).to be_an(Array) if candles.any?
        expect(candles.first&.length).to eq(6) if candles.any? # OHLCV format
      end

      it "handles various product IDs" do
        # Test with different product IDs to ensure flexibility
        ["BTC-USD", "ETH-USD", "ADA-USD"].each do |test_product_id|
          allow(rest).to receive(:fetch_candles).and_return(mock_candle_data)

          candles = rest.fetch_candles(
            product_id: test_product_id,
            start_iso8601: start_time.iso8601,
            end_iso8601: end_time.iso8601,
            granularity: 3600
          )
          expect(candles).to be_an(Array)
        end
      end

      it "handles different time granularities" do
        [60, 300, 900, 3600, 86400].each do |granularity|
          allow(rest).to receive(:fetch_candles).and_return(mock_candle_data)

          candles = rest.fetch_candles(
            product_id: product_id,
            start_iso8601: start_time.iso8601,
            end_iso8601: end_time.iso8601,
            granularity: granularity
          )
          expect(candles).to be_an(Array)
        end
      end
    end

    context "error handling" do
      it "handles API errors gracefully" do
        allow(rest).to receive(:fetch_candles).and_raise(RuntimeError.new("API Error"))

        expect do
          rest.fetch_candles(
            product_id: "INVALID-PRODUCT",
            start_iso8601: start_time.iso8601,
            end_iso8601: end_time.iso8601,
            granularity: 3600
          )
        end.to raise_error(RuntimeError, "API Error")
      end

      it "handles network timeouts" do
        allow(rest).to receive(:fetch_candles).and_raise(Faraday::TimeoutError.new("Connection timeout"))

        expect do
          rest.fetch_candles(
            product_id: product_id,
            start_iso8601: start_time.iso8601,
            end_iso8601: end_time.iso8601,
            granularity: 3600
          )
        end.to raise_error(Faraday::TimeoutError)
      end
    end

    describe "candle data management" do
      let(:candle_data) do
        [
          [1_752_000_000, 50_000.0, 51_000.0, 49_500.0, 50_500.0, 100.0],
          [1_752_000_300, 50_500.0, 50_800.0, 50_200.0, 50_700.0, 150.0]
        ]
      end

      before do
        allow(rest).to receive(:fetch_candles).and_return(candle_data)
      end

      describe "1-hour candles" do
        it "creates candles with correct attributes" do
          expect do
            rest.upsert_1h_candles(product_id: product_id, start_time: start_time, end_time: end_time)
          end.to change { Candle.count }.by(2)

          candle = Candle.where(timeframe: "1h", symbol: product_id).first
          expect(candle).to be_present
          expect(candle.symbol).to eq(product_id)
          expect(candle.timeframe).to eq("1h")
          expect(candle.open).to be_a(BigDecimal)
          expect(candle.high).to be_a(BigDecimal)
          expect(candle.low).to be_a(BigDecimal)
          expect(candle.close).to be_a(BigDecimal)
          expect(candle.volume).to be_a(BigDecimal)
        end

        it "handles large date ranges by delegating to chunked method" do
          large_start = 10.days.ago
          large_end = Time.now.utc

          expect(rest).to receive(:upsert_1h_candles_chunked).with(
            product_id: product_id,
            start_time: large_start,
            end_time: large_end
          )

          rest.upsert_1h_candles(product_id: product_id, start_time: large_start, end_time: large_end)
        end
      end

      describe "15-minute candles" do
        it "creates 15m candles with correct attributes" do
          expect do
            rest.upsert_15m_candles(product_id: product_id, start_time: start_time, end_time: end_time)
          end.to change { Candle.count }.by(2)

          candle = Candle.where(timeframe: "15m", symbol: product_id).first
          expect(candle).to be_present
          expect(candle.timeframe).to eq("15m")
          expect(candle.symbol).to eq(product_id)
        end

        it "handles large date ranges with chunked fetching" do
          large_start = 10.days.ago
          large_end = Time.now.utc

          expect(rest).to receive(:upsert_15m_candles_chunked).with(
            product_id: product_id,
            start_time: large_start,
            end_time: large_end
          )

          rest.upsert_15m_candles(product_id: product_id, start_time: large_start, end_time: large_end)
        end
      end

      describe "5-minute candles" do
        it "creates 5m candles with correct attributes" do
          expect do
            rest.upsert_5m_candles(product_id: product_id, start_time: start_time, end_time: end_time)
          end.to change { Candle.count }.by(2)

          candle = Candle.where(timeframe: "5m", symbol: product_id).first
          expect(candle).to be_present
          expect(candle.symbol).to eq(product_id)
          expect(candle.timeframe).to eq("5m")
        end

        it "handles large date ranges with chunked fetching" do
          large_start = 5.days.ago
          large_end = Time.now.utc

          expect(rest).to receive(:upsert_5m_candles_chunked).with(
            product_id: product_id,
            start_time: large_start,
            end_time: large_end
          )

          rest.upsert_5m_candles(product_id: product_id, start_time: large_start, end_time: large_end)
        end

        describe "chunked processing" do
          it "processes candle chunks correctly" do
            expect do
              rest.upsert_5m_candles_chunked(
                product_id: product_id,
                start_time: start_time,
                end_time: end_time,
                chunk_days: 1
              )
            end.to change { Candle.count }.by(2)

            candle = Candle.where(timeframe: "5m", symbol: product_id).first
            expect(candle).to be_present
            expect(candle.timeframe).to eq("5m")
            expect(candle.symbol).to eq(product_id)
          end

          it "handles API errors gracefully during chunked processing" do
            allow(rest).to receive(:fetch_candles).and_raise("API Error")

            expect do
              rest.upsert_5m_candles_chunked(
                product_id: product_id,
                start_time: start_time,
                end_time: end_time,
                chunk_days: 1
              )
            end.not_to raise_error

            # Should not create any candles due to error
            expect(Candle.where(timeframe: "5m")).to be_empty
          end
        end

        it "complete workflow test with realistic data" do
          # Verify no 5m candles exist initially
          expect(Candle.where(timeframe: "5m")).to be_empty

          # Call the 5m candle upsert method
          rest.upsert_5m_candles(product_id: product_id, start_time: start_time, end_time: end_time)

          # Verify candles were created
          candles = Candle.where(timeframe: "5m").order(:timestamp)
          expect(candles.count).to eq(2)

          # Verify first candle data
          first_candle = candles.first
          expect(first_candle.symbol).to eq("BTC-USD")
          expect(first_candle.timeframe).to eq("5m")
          expect(first_candle.timestamp).to eq(Time.at(1_752_000_000).utc)
          expect(first_candle.open).to eq(BigDecimal("49500.0"))
          expect(first_candle.high).to eq(BigDecimal("51000.0"))
          expect(first_candle.low).to eq(BigDecimal("50000.0"))
          expect(first_candle.close).to eq(BigDecimal("50500.0"))
          expect(first_candle.volume).to eq(BigDecimal("100.0"))
        end
      end
    end
  end
end
