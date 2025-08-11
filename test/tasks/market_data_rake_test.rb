# frozen_string_literal: true

require "test_helper"
require "rake"

class MarketDataRakeTest < ActiveJob::TestCase
  def setup
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    # Create a trading pair for testing
    @btc_pair = TradingPair.create!(
      product_id: "BTC-USD",
      base_currency: "BTC",
      quote_currency: "USD",
      status: "online",
      min_size: "0.001",
      price_increment: "0.01",
      size_increment: "0.001",
      enabled: true
    )
  end

  def teardown
    TradingPair.destroy_all
    Candle.destroy_all
  end

  def test_subscribe_task_enqueues_job_with_args
    assert_enqueued_with(job: MarketDataSubscribeJob, args: [ [ "BTC-USD-PERP", "ETH-USD-PERP" ] ]) do
      Rake::Task["market_data:subscribe"].reenable
      Rake::Task["market_data:subscribe"].invoke("BTC-USD-PERP,ETH-USD-PERP")
    end
  end

  def test_subscribe_task_uses_env_product_ids
    ENV["PRODUCT_IDS"] = "BTC-USD-PERP"
    begin
      assert_enqueued_with(job: MarketDataSubscribeJob, args: [ [ "BTC-USD-PERP" ] ]) do
        Rake::Task["market_data:subscribe"].reenable
        Rake::Task["market_data:subscribe"].invoke(nil)
      end
    ensure
      ENV.delete("PRODUCT_IDS")
    end
  end

  def test_subscribe_task_uses_default_product_ids
    assert_enqueued_with(job: MarketDataSubscribeJob, args: [ [ "BTC-USD-PERP" ] ]) do
      Rake::Task["market_data:subscribe"].reenable
      Rake::Task["market_data:subscribe"].invoke(nil)
    end
  end

  def test_upsert_futures_products_task
    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_products, nil
    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:upsert_futures_products"].reenable
      Rake::Task["market_data:upsert_futures_products"].invoke
    end
    mock_rest.verify
  end

  def test_backfill_candles_task_enqueues_job
    assert_enqueued_with(job: FetchCandlesJob, args: [ { backfill_days: 7 } ]) do
      Rake::Task["market_data:backfill_candles"].reenable
      Rake::Task["market_data:backfill_candles"].invoke(7)
    end
  end

  def test_backfill_candles_task_uses_default_days
    assert_enqueued_with(job: FetchCandlesJob, args: [ { backfill_days: 30 } ]) do
      Rake::Task["market_data:backfill_candles"].reenable
      Rake::Task["market_data:backfill_candles"].invoke(nil)
    end
  end

  def test_backfill_1h_candles_task_success
    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_1h_candles, nil

    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:backfill_1h_candles"].reenable
      Rake::Task["market_data:backfill_1h_candles"].invoke(1)
    end
    mock_rest.verify
  end

  def test_backfill_1h_candles_task_without_trading_pair
    # Remove the trading pair
    @btc_pair.destroy!

    # Mock the CoinbaseRest service to avoid actual API calls
    mock_rest = Minitest::Mock.new
    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:backfill_1h_candles"].reenable
      Rake::Task["market_data:backfill_1h_candles"].invoke(1)
    end

    # Should not raise an error, just return early
    assert true
  end

  def test_backfill_30m_candles_task_success
    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_30m_candles, nil

    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:backfill_30m_candles"].reenable
      Rake::Task["market_data:backfill_30m_candles"].invoke(1)
    end
    mock_rest.verify
  end

  def test_backfill_30m_candles_task_without_trading_pair
    # Remove the trading pair
    @btc_pair.destroy!

    # Mock the CoinbaseRest service to avoid actual API calls
    mock_rest = Minitest::Mock.new
    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:backfill_30m_candles"].reenable
      Rake::Task["market_data:backfill_30m_candles"].invoke(1)
    end

    # Should not raise an error, just return early
    assert true
  end

  def test_test_1h_candles_task
    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_1h_candles, nil

    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:test_1h_candles"].reenable
      Rake::Task["market_data:test_1h_candles"].invoke(1)
    end
    mock_rest.verify
  end

  def test_test_granularities_task
    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    # Expect multiple calls to fetch_candles with different granularities
    7.times { mock_rest.expect :fetch_candles, [] }

    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:test_granularities"].reenable
      Rake::Task["market_data:test_granularities"].invoke
    end
    mock_rest.verify
  end

  def test_backfill_1h_candles_task_counts_candles
    # Create some existing candles
    Candle.create!(
      symbol: "BTC-USD",
      timeframe: "1h",
      timestamp: 1.hour.ago,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )

    # Mock the CoinbaseRest service
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_1h_candles, nil

    MarketData::CoinbaseRest.stub :new, mock_rest do
      Rake::Task["market_data:backfill_1h_candles"].reenable
      Rake::Task["market_data:backfill_1h_candles"].invoke(1)
    end

    # The task should report the existing candle count
    assert_equal 1, Candle.where(symbol: "BTC-USD", timeframe: "1h").count
    mock_rest.verify
  end
end
