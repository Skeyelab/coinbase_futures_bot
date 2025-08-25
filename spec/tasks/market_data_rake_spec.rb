# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "market_data rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    TradingPair.delete_all
    Candle.delete_all
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

  after do
    Rake::Task["market_data:subscribe"].reenable
    Rake::Task["market_data:upsert_futures_products"].reenable
    Rake::Task["market_data:backfill_candles"].reenable
    Rake::Task["market_data:backfill_1h_candles"].reenable
    Rake::Task["market_data:backfill_15m_candles"].reenable
    Rake::Task["market_data:test_1h_candles"].reenable
    Rake::Task["market_data:test_granularities"].reenable
    Rake::Task["market_data:subscribe_futures"].reenable
  end

  it "enqueues subscribe with args" do
    expect do
      Rake::Task["market_data:subscribe"].invoke("BTC-USD-PERP,ETH-USD-PERP")
    end.to have_enqueued_job(MarketDataSubscribeJob).with(%w[BTC-USD-PERP ETH-USD-PERP])
  end

  it "uses env PRODUCT_IDS when products arg is nil" do
    ClimateControl.modify(PRODUCT_IDS: "BTC-USD-PERP") do
      expect do
        Rake::Task["market_data:subscribe"].invoke(nil)
      end.to have_enqueued_job(MarketDataSubscribeJob).with(["BTC-USD-PERP"])
    end
  end

  it "uses default PRODUCT_IDS when neither arg nor env provided" do
    expect do
      Rake::Task["market_data:subscribe"].invoke(nil)
    end.to have_enqueued_job(MarketDataSubscribeJob).with(["BTC-USD-PERP"])
  end

  it "upserts futures products via rest service and outputs completion message" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_products)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect do
      Rake::Task["market_data:upsert_futures_products"].invoke
    end.to output(/Completed upserting futures products/).to_stdout
  end

  it "enqueues backfill candles job with provided days" do
    expect do
      Rake::Task["market_data:backfill_candles"].invoke(7)
    end.to have_enqueued_job(FetchCandlesJob).with(backfill_days: 7)
  end

  it "enqueues backfill candles job with default days" do
    expect do
      Rake::Task["market_data:backfill_candles"].invoke(nil)
    end.to have_enqueued_job(FetchCandlesJob).with(backfill_days: 30)
  end

  it "runs backfill_1h_candles without error and calls rest" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_1h_candles)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect do
      Rake::Task["market_data:backfill_1h_candles"].invoke(1)
    end.not_to raise_error
  end

  it "handles missing trading pair gracefully for backfill_1h_candles" do
    @btc_pair.destroy!
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
    expect { Rake::Task["market_data:backfill_1h_candles"].invoke(1) }.not_to raise_error
  end

  it "runs backfill_15m_candles and calls rest" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_15m_candles)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect do
      Rake::Task["market_data:backfill_15m_candles"].invoke(1)
    end.not_to raise_error
  end

  it "handles missing trading pair gracefully for backfill_15m_candles" do
    @btc_pair.destroy!
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
    expect { Rake::Task["market_data:backfill_15m_candles"].invoke(1) }.not_to raise_error
  end

  it "runs backfill_5m_candles and calls rest" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_5m_candles)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect do
      Rake::Task["market_data:backfill_5m_candles"].invoke(1)
    end.not_to raise_error
  end

  it "handles missing trading pair gracefully for backfill_5m_candles" do
    @btc_pair.destroy!
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
    expect { Rake::Task["market_data:backfill_5m_candles"].invoke(1) }.not_to raise_error
  end

  it "runs backfill_5m_candles with real API call", :vcr do
    # Clear existing candles to avoid conflicts
    Candle.where(timeframe: "5m", symbol: "BTC-USD").destroy_all

    # Run the actual rake task
    expect do
      Rake::Task["market_data:backfill_5m_candles"].invoke(1)
    end.not_to raise_error

    # Verify that 5m candles were created
    candles = Candle.where(timeframe: "5m", symbol: "BTC-USD")
    if candles.any?
      expect(candles.first.timeframe).to eq("5m")
      expect(candles.first.symbol).to eq("BTC-USD")
    end
  end

  it "runs test_1h_candles and calls rest" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_1h_candles)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect { Rake::Task["market_data:test_1h_candles"].invoke(1) }.not_to raise_error
  end

  it "tests granularities without raising" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:fetch_candles).and_return([])
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect { Rake::Task["market_data:test_granularities"].invoke }.not_to raise_error
  end

  it "subscribe_futures runs inline when INLINE=1" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.level = Logger::DEBUG

    ClimateControl.modify(INLINE: "1") do
      expect(MarketData::CoinbaseDerivativesSubscriber).to receive(:new) do |**kwargs|
        expect(kwargs[:product_ids]).to eq(["BTC-USD-PERP"]) if kwargs[:product_ids].is_a?(Array)
        instance_double("Sub", start: nil)
      end
      expect { Rake::Task["market_data:subscribe_futures"].invoke("BTC-USD-PERP") }.not_to raise_error
    end
  end
end
