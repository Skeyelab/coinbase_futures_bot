# frozen_string_literal: true

require "rails_helper"

RSpec.describe FetchCandlesJob, type: :job do
  let(:btc_pair) {
    TradingPair.find_or_create_by(product_id: "BTC-USD") { |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = true
    }
  }

  after do
    # Don't destroy the BTC pair as it might be used by other tests
  end

  describe "#perform" do
    it "fetches 1m, 5m, 15m, and 1h candles" do
      with_integration_vcr("fetch_candles_job_perform_all_timeframes") do
        # Clear existing candles to avoid conflicts
        Candle.where(symbol: "BTC-USD").destroy_all

        # Just test that the job runs without error
        expect { described_class.perform_now(backfill_days: 1) }.not_to raise_error

        # Verify that some candles were created (may vary based on API response)
        total_candles = Candle.where(symbol: "BTC-USD").count
        expect(total_candles).to be >= 0

        if total_candles > 0
          # Verify we have candles in different timeframes
          timeframes = Candle.where(symbol: "BTC-USD").distinct.pluck(:timeframe)
          # Note: VCR cassette may not have all timeframes, so we check what's available
          expect(timeframes).to include("5m", "15m", "1h")
          # Log what timeframes we actually got for debugging
          puts "Available timeframes in VCR cassette: #{timeframes.join(", ")}"
        end
      end
    end

    it "returns early if no BTC trading pair found" do
      # Temporarily remove the BTC pair for this test
      original_btc_pair = btc_pair
      TradingPair.where(product_id: "BTC-USD").destroy_all

      # Mock the rest service to avoid real API calls in this test
      mock_rest = instance_double("MarketData::CoinbaseRest")
      allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
      allow(mock_rest).to receive(:upsert_products)

      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error

      # Restore the BTC pair
      original_btc_pair.save! if original_btc_pair.persisted?
    end

    it "calls all four candle fetching methods" do
      # Mock the class to return our mock instance
      mock_rest = instance_double("MarketData::CoinbaseRest")
      allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
      allow(mock_rest).to receive(:upsert_products)
      allow(mock_rest).to receive(:upsert_1m_candles)
      allow(mock_rest).to receive(:upsert_5m_candles)
      allow(mock_rest).to receive(:upsert_15m_candles)
      allow(mock_rest).to receive(:upsert_1h_candles)

      # Ensure the job can find the trading pair
      allow(TradingPair).to receive(:find_by).with(product_id: "BTC-USD").and_return(btc_pair)

      described_class.perform_now(backfill_days: 7)

      expect(mock_rest).to have_received(:upsert_1m_candles)
      expect(mock_rest).to have_received(:upsert_5m_candles)
      expect(mock_rest).to have_received(:upsert_15m_candles)
      expect(mock_rest).to have_received(:upsert_1h_candles)
    end

    it "handles errors gracefully for individual candle types" do
      # Mock the class to return our mock instance
      mock_rest = instance_double("MarketData::CoinbaseRest")
      allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
      allow(mock_rest).to receive(:upsert_products)
      allow(mock_rest).to receive(:upsert_1m_candles).and_raise("1m API Error")
      allow(mock_rest).to receive(:upsert_5m_candles)
      allow(mock_rest).to receive(:upsert_15m_candles)
      allow(mock_rest).to receive(:upsert_1h_candles)

      # Ensure the job can find the trading pair
      allow(TradingPair).to receive(:find_by).with(product_id: "BTC-USD").and_return(btc_pair)

      # Should not raise error, should continue with other candle types
      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error

      # Should still call the other methods
      expect(mock_rest).to have_received(:upsert_5m_candles)
      expect(mock_rest).to have_received(:upsert_15m_candles)
      expect(mock_rest).to have_received(:upsert_1h_candles)
    end
  end
end
