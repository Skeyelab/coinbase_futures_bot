# frozen_string_literal: true

require "rails_helper"

RSpec.describe FetchCandlesJob, type: :job do
  let(:btc_pair) do
    Contract.find_or_create_by(product_id: "BIT-26JUN26-CDE") do |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.status = "active"
      tp.enabled = true
      tp.expiration_date = Date.new(2026, 6, 26)
    end
  end

  def stub_rest(mock_rest)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
    allow(mock_rest).to receive(:upsert_products)
    allow(mock_rest).to receive(:upsert_1m_candles)
    allow(mock_rest).to receive(:upsert_5m_candles)
    allow(mock_rest).to receive(:upsert_15m_candles)
    allow(mock_rest).to receive(:upsert_30m_candles)
    allow(mock_rest).to receive(:upsert_1h_candles)
    allow(mock_rest).to receive(:upsert_1d_candles)
    allow(Rails.logger).to receive(:info)
  end

  describe "#perform" do
    it "fetches candles for all enabled pairs" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)

      btc_pair
      expect { described_class.perform_now(backfill_days: 1) }.not_to raise_error
      expect(mock_rest).to have_received(:upsert_products)
      expect(mock_rest).to have_received(:upsert_1h_candles).with(hash_including(product_id: "BIT-26JUN26-CDE"))
    end

    it "returns early if no enabled trading pairs found" do
      Contract.update_all(enabled: false)

      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)

      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error
      expect(mock_rest).to have_received(:upsert_products)
      expect(mock_rest).not_to have_received(:upsert_1h_candles)
    end

    it "calls all six candle timeframe methods per pair" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)

      btc_pair
      described_class.perform_now(backfill_days: 7)

      expect(mock_rest).to have_received(:upsert_1m_candles).once
      expect(mock_rest).to have_received(:upsert_5m_candles).once
      expect(mock_rest).to have_received(:upsert_15m_candles).once
      expect(mock_rest).to have_received(:upsert_30m_candles).once
      expect(mock_rest).to have_received(:upsert_1h_candles).once
      expect(mock_rest).to have_received(:upsert_1d_candles).once
    end

    it "handles errors gracefully for individual candle timeframes" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      allow(mock_rest).to receive(:upsert_1m_candles).and_raise("1m API Error")
      allow(Rails.logger).to receive(:error)
      allow(Sentry).to receive(:with_scope).and_yield(double("scope").as_null_object)
      allow(Sentry).to receive(:capture_exception)

      btc_pair
      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error
      expect(mock_rest).to have_received(:upsert_5m_candles).once
      expect(mock_rest).to have_received(:upsert_15m_candles).once
      expect(mock_rest).to have_received(:upsert_30m_candles).once
      expect(mock_rest).to have_received(:upsert_1h_candles).once
      expect(mock_rest).to have_received(:upsert_1d_candles).once
    end
  end
end
