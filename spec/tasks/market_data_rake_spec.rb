# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "market_data rake tasks", type: :task do
  before do
    # Clear job queues before each test
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    # Load tasks if not already loaded
    Rails.application.load_tasks unless Rake::Task.task_defined?("market_data:subscribe")

    # Re-enable tasks before each test
    Rake::Task["market_data:subscribe"].reenable
    Rake::Task["market_data:upsert_futures_products"].reenable
    Rake::Task["market_data:backfill_candles"].reenable
    Rake::Task["market_data:backfill"].reenable
    Rake::Task["market_data:test_granularities"].reenable
    Rake::Task["market_data:subscribe_futures"].reenable

    Contract.delete_all
    Candle.delete_all
    @btc_pair = Contract.create!(
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

  it "enqueues subscribe with args" do
    expect do
      Rake::Task["market_data:subscribe"].invoke("BTC-USD,ETH-USD")
    end.to have_enqueued_job(MarketDataSubscribeJob).with(%w[BTC-USD ETH-USD])
  end

  it "uses env PRODUCT_IDS when products arg is nil" do
    ClimateControl.modify(PRODUCT_IDS: "BTC-USD") do
      expect do
        Rake::Task["market_data:subscribe"].invoke(nil)
      end.to have_enqueued_job(MarketDataSubscribeJob).with(["BTC-USD"])
    end
  end

  it "uses default PRODUCT_IDS when neither arg nor env provided" do
    expect do
      Rake::Task["market_data:subscribe"].invoke(nil)
    end.to have_enqueued_job(MarketDataSubscribeJob).with(["BTC-USD"])
  end

  it "upserts futures products via rest service and outputs completion message" do
    mock_rest = instance_double(MarketData::CoinbaseRest)
    allow(mock_rest).to receive(:upsert_products)
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)

    expect do
      Rake::Task["market_data:upsert_futures_products"].invoke
    end.to output(/Completed upserting futures products/).to_stdout
  end

  it "runs parameterized backfill for the given products (issue #342)" do
    expect(FetchCandlesJob).to receive(:perform_now)
      .with(backfill_days: 60, symbols: ["ETH-USD", "NOL-19AUG26-CDE"], max_1m_days: nil)

    expect do
      Rake::Task["market_data:backfill"].invoke("60", "ETH-USD NOL-19AUG26-CDE")
    end.to output(/Backfilling 60d/).to_stdout
  end

  it "enqueues on the low queue when async is requested (deep backfills)" do
    expect do
      Rake::Task["market_data:backfill"].invoke("90", "BTC-USD", "90", "async")
    end.to have_enqueued_job(FetchCandlesJob)
      .with(backfill_days: 90, symbols: ["BTC-USD"], max_1m_days: 90)
      .on_queue("low")
  end

  it "backfills all enabled contracts when no products are given" do
    expect(FetchCandlesJob).to receive(:perform_now).with(backfill_days: 30, symbols: nil, max_1m_days: nil)

    expect do
      Rake::Task["market_data:backfill"].invoke(nil, nil)
    end.to output(/ALL enabled contracts/).to_stdout
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
        expect(kwargs[:product_ids]).to eq(["BTC-USD"]) if kwargs[:product_ids].is_a?(Array)
        instance_double("Sub", start: nil)
      end
      expect { Rake::Task["market_data:subscribe_futures"].invoke("BTC-USD") }.not_to raise_error
    end
  end
end
