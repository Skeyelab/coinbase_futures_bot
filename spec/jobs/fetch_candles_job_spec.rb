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
      # The cap is a STEADY-STATE figure: it governs keeping an already-deep
      # contract current. A contract that has never had its one-time deep
      # backfill gets the deep window instead, which is the #506 fix and is
      # covered in fetch_candles_job_deep_1m_spec.rb. Stamping the fixture is
      # what puts this example in the steady state it means to test.
      btc_pair.update!(deep_1m_backfilled_at: 1.day.ago)

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

  # Production hit this ~2,000 times: once a timeframe's newest stored candle
  # exists, the incremental start is newest + step, which for a daily bar is
  # TOMORROW. Nothing clamped it to now, so the job asked Coinbase for a window
  # running backwards and got a 400 every run.
  #
  #   GET .../candles?end=1785650723&granularity=ONE_DAY&start=1785715200
  #                       Aug 1 06:05Z                        Aug 2 00:00Z
  #
  # The cost was not just noise: the current day's 1d candle stopped refreshing
  # until the next day rolled over.
  describe "inverted fetch windows" do
    let(:now) { Time.utc(2026, 8, 1, 6, 5, 23) }

    before { allow(Time).to receive(:now).and_return(now) }

    def store_candle(timeframe, timestamp)
      Candle.find_or_create_by!(symbol: btc_pair.product_id, timeframe: timeframe, timestamp: timestamp) do |c|
        c.open = 100.0
        c.high = 101.0
        c.low = 99.0
        c.close = 100.5
        c.volume = 1.0
      end
    end

    # Deep history matters: with only a recent candle the job takes the
    # shallow-history branch and refetches from the cutoff, which is a valid
    # window. The production bug needs history older than the cutoff PLUS a
    # current bar, so the incremental branch is the one that runs.
    it "does not ask for daily candles when the newest bar is already today" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      store_candle("1d", Time.utc(2026, 7, 20))
      store_candle("1d", Time.utc(2026, 8, 1))

      described_class.perform_now(backfill_days: 7)

      expect(mock_rest).not_to have_received(:upsert_1d_candles)
    end

    it "still fetches daily candles when there is a real window to fetch" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      store_candle("1d", Time.utc(2026, 7, 20))
      store_candle("1d", Time.utc(2026, 7, 30))

      described_class.perform_now(backfill_days: 7)

      expect(mock_rest).to have_received(:upsert_1d_candles) do |args|
        expect(args[:start_time]).to be < args[:end_time]
      end
    end

    it "never hands the client a window that runs backwards, on any timeframe" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      # 30m is absent on purpose: it is not a valid Candle timeframe
      # (1m 5m 15m 1h 6h 1d), so it can never hold stored candles and can
      # never reach the incremental branch.
      %w[1m 5m 15m 1h 1d].each do |tf|
        # Old enough to sit behind every timeframe's backfill cutoff,
        # including the deep 1m window, so each one takes the incremental
        # branch rather than refetching from its cutoff.
        store_candle(tf, Time.utc(2020, 1, 1))
        store_candle(tf, now + 1.day)
      end

      described_class.perform_now(backfill_days: 7)

      %i[upsert_1m_candles upsert_5m_candles upsert_15m_candles
        upsert_1h_candles upsert_1d_candles
        upsert_1m_candles_chunked upsert_5m_candles_chunked
        upsert_15m_candles_chunked upsert_1h_candles_chunked].each do |call|
        expect(mock_rest).not_to have_received(call)
      end
    end

    # Not calling the client is only half of it. Without the per-timeframe
    # guard, start_time is nil and `Time.now.utc - nil` raises, which the
    # rescue swallows into an error log and a Sentry event. That skips the
    # fetch too, so a call-count assertion alone passes for the wrong reason
    # and reproduces the very noise this fix removes. A skip must be silent.
    it "skips quietly instead of raising into the error handler" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      allow(Rails.logger).to receive(:error)
      allow(Sentry).to receive(:with_scope).and_yield(double("scope").as_null_object)
      allow(Sentry).to receive(:capture_exception)
      %w[1m 5m 15m 1h 1d].each do |tf|
        store_candle(tf, Time.utc(2020, 1, 1))
        store_candle(tf, now + 1.day)
      end

      described_class.perform_now(backfill_days: 7)

      expect(Sentry).not_to have_received(:capture_exception)
      expect(Rails.logger).not_to have_received(:error)
    end

    # start == now is an empty window, not a fetchable one.
    it "treats a window that starts exactly now as nothing to fetch" do
      mock_rest = instance_double(MarketData::CoinbaseRest)
      stub_rest(mock_rest)
      allow(Rails.logger).to receive(:error)
      allow(Sentry).to receive(:capture_exception)
      store_candle("1d", Time.utc(2020, 1, 1))
      store_candle("1d", now - 1.day)

      described_class.perform_now(backfill_days: 7)

      expect(mock_rest).not_to have_received(:upsert_1d_candles)
      expect(Sentry).not_to have_received(:capture_exception)
    end
  end
end
