# frozen_string_literal: true

require "rails_helper"

RSpec.describe FetchCandlesJob, type: :job do
  let(:btc_pair) do
    Contract.find_or_create_by(product_id: "BIT-26JUN26-CDE") do |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.status = "active"
      tp.enabled = true
      tp.expiration_date = Date.current + 60
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
    allow(mock_rest).to receive(:upsert_1m_candles_chunked)
    allow(mock_rest).to receive(:upsert_5m_candles_chunked)
    allow(mock_rest).to receive(:upsert_15m_candles_chunked)
    allow(mock_rest).to receive(:upsert_1h_candles_chunked)
    allow(Rails.logger).to receive(:info)
  end

  describe "expired contract auto-disable (issue #368)" do
    it "disables contracts past expiration so nothing keeps targeting them" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      expired = Contract.find_or_create_by(product_id: "NOL-20JUL26-CDE") do |tp|
        tp.base_currency = "OIL"
        tp.quote_currency = "USD"
        tp.status = "active"
        tp.enabled = true
        tp.expiration_date = Date.current - 1
      end
      btc_pair

      described_class.perform_now(backfill_days: 1)

      expect(expired.reload.enabled).to be false
      expect(btc_pair.reload.enabled).to be true
      expect(mock_rest).not_to have_received(:upsert_1h_candles).with(hash_including(product_id: "NOL-20JUL26-CDE"))
    end
  end

  describe "deep backfill (issue #342)" do
    let(:mock_rest) { instance_double(MarketData::CoinbaseRest) }

    before do
      stub_rest(mock_rest)
      btc_pair
    end

    it "honors backfill_days for 5m instead of silently capping at 1 day" do
      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_5m_candles_chunked).with(
        hash_including(product_id: "BIT-26JUN26-CDE",
          start_time: satisfy { |t| t <= 59.days.ago })
      )
    end

    it "honors backfill_days for 15m instead of silently capping at 3 days" do
      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_15m_candles_chunked).with(
        hash_including(start_time: satisfy { |t| t <= 59.days.ago })
      )
    end

    it "caps 1m depth (API request budget) but honors more than the old 6-hour limit" do
      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_1m_candles_chunked).with(
        hash_including(start_time: satisfy { |t| t.between?(4.days.ago, 2.days.ago) })
      )
    end

    it "allows deep 1m backfill via max_1m_days for deliberate long-range validation (issue #378)" do
      described_class.perform_now(backfill_days: 60, max_1m_days: 60)

      expect(mock_rest).to have_received(:upsert_1m_candles_chunked).with(
        hash_including(start_time: satisfy { |t| t <= 59.days.ago })
      )
    end

    it "filters to the requested symbols" do
      Contract.find_or_create_by(product_id: "ET-26JUN26-CDE") do |tp|
        tp.base_currency = "ETH"
        tp.quote_currency = "USD"
        tp.status = "active"
        tp.enabled = true
        tp.expiration_date = Date.current + 60
      end

      described_class.perform_now(backfill_days: 1, symbols: ["ET-26JUN26-CDE"])

      expect(mock_rest).to have_received(:upsert_1h_candles).with(hash_including(product_id: "ET-26JUN26-CDE"))
      expect(mock_rest).not_to have_received(:upsert_1h_candles).with(hash_including(product_id: "BIT-26JUN26-CDE"))
    end

    it "keeps small incremental fetches unchunked (hourly cron path)" do
      # Cron path: history already reaches the requested cutoff AND recent
      # candles exist -> only the tiny (last..now) window is fetched.
      [61.days.ago, 10.minutes.ago].each do |ts|
        Candle.create!(symbol: "BIT-26JUN26-CDE", timeframe: "5m", timestamp: ts,
          open: 100, high: 101, low: 99, close: 100, volume: 1)
      end

      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_5m_candles)
      expect(mock_rest).not_to have_received(:upsert_5m_candles_chunked)
    end

    it "chunks deep 1h backfills at 14 days so requests stay under the ~350-candle API cap (issue #368)" do
      # 30-day chunks = 720 hourly candles/request; the API truncates to ~350,
      # which capped 1h history at ~168 candles on exo-mini.
      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_1h_candles_chunked).with(
        hash_including(chunk_days: 14, start_time: satisfy { |t| t <= 59.days.ago })
      )
    end

    it "fills BACKWARD when existing history is shallower than backfill_days" do
      # The first #342 fix only helped cold starts: with any recent candle,
      # start anchored to (last + step) and deep history was never fetched.
      # Shallow history must trigger a full-window refetch (upserts dedupe).
      Candle.create!(symbol: "BIT-26JUN26-CDE", timeframe: "5m", timestamp: 10.minutes.ago,
        open: 100, high: 101, low: 99, close: 100, volume: 1)

      described_class.perform_now(backfill_days: 60)

      expect(mock_rest).to have_received(:upsert_5m_candles_chunked).with(
        hash_including(start_time: satisfy { |t| t <= 59.days.ago })
      )
    end
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

      # 7-day cold backfill: sub-day timeframes route through chunked fetching
      expect(mock_rest).to have_received(:upsert_1m_candles_chunked).once
      expect(mock_rest).to have_received(:upsert_5m_candles_chunked).once
      expect(mock_rest).to have_received(:upsert_15m_candles_chunked).once
      expect(mock_rest).to have_received(:upsert_30m_candles).once
      expect(mock_rest).to have_received(:upsert_1h_candles).once
      expect(mock_rest).to have_received(:upsert_1d_candles).once
    end

    it "handles errors gracefully for individual candle timeframes" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      allow(mock_rest).to receive(:upsert_1m_candles_chunked).and_raise("1m API Error")
      allow(Rails.logger).to receive(:error)
      allow(Sentry).to receive(:with_scope).and_yield(double("scope").as_null_object)
      allow(Sentry).to receive(:capture_exception)

      btc_pair
      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error
      expect(mock_rest).to have_received(:upsert_5m_candles_chunked).once
      expect(mock_rest).to have_received(:upsert_15m_candles_chunked).once
      expect(mock_rest).to have_received(:upsert_30m_candles).once
      expect(mock_rest).to have_received(:upsert_1h_candles).once
      expect(mock_rest).to have_received(:upsert_1d_candles).once
    end
  end
end
