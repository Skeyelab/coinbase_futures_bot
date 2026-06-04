# frozen_string_literal: true

require "rails_helper"

RSpec.describe FetchCandlesJob, type: :job do
  let(:btc_pair) do
    TradingPair.find_or_create_by(product_id: "BTC-USD") do |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = true
    end
  end

  let(:eth_pair) do
    TradingPair.find_or_create_by(product_id: "ETH-USD") do |tp|
      tp.base_currency = "ETH"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = true
    end
  end

  after do
    # Don't destroy the BTC and ETH pairs as they might be used by other tests
  end

  describe "#perform" do
    it "fetches candles for all enabled pairs" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
      allow(mock_rest).to receive(:upsert_products)
      allow(mock_rest).to receive(:upsert_1m_candles)
      allow(mock_rest).to receive(:upsert_5m_candles)
      allow(mock_rest).to receive(:upsert_15m_candles)
      allow(mock_rest).to receive(:upsert_1h_candles)
      allow(Rails.logger).to receive(:info)

      btc_pair
      expect { described_class.perform_now(backfill_days: 1) }.not_to raise_error
      expect(mock_rest).to have_received(:upsert_products)
      expect(mock_rest).to have_received(:upsert_1h_candles).with(hash_including(product_id: "BTC-USD"))
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

      # Ensure the job can find the trading pairs
      allow(TradingPair).to receive(:find_by).with(product_id: "BTC-USD").and_return(btc_pair)
      allow(TradingPair).to receive(:find_by).with(product_id: "ETH-USD").and_return(eth_pair)

      described_class.perform_now(backfill_days: 7)

      # Each method should be called twice (once for BTC-USD, once for ETH-USD)
      expect(mock_rest).to have_received(:upsert_1m_candles).twice
      expect(mock_rest).to have_received(:upsert_5m_candles).twice
      expect(mock_rest).to have_received(:upsert_15m_candles).twice
      expect(mock_rest).to have_received(:upsert_1h_candles).twice
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

      # Ensure the job can find the trading pairs
      allow(TradingPair).to receive(:find_by).with(product_id: "BTC-USD").and_return(btc_pair)
      allow(TradingPair).to receive(:find_by).with(product_id: "ETH-USD").and_return(eth_pair)

      # Should not raise error, should continue with other candle types
      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error

      # Should still call the other methods (twice for each pair, even though 1m fails)
      expect(mock_rest).to have_received(:upsert_5m_candles).twice
      expect(mock_rest).to have_received(:upsert_15m_candles).twice
      expect(mock_rest).to have_received(:upsert_1h_candles).twice
    end
  end
end
