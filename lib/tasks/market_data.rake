# frozen_string_literal: true

namespace :market_data do
  desc "Subscribe to Coinbase futures ticker (GoodJob async)"
  task :subscribe, [ :products ] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD-PERP").split(",")

    if ENV["INLINE"].to_s == "1"
      stdout_logger = Logger.new($stdout)
      stdout_logger.level = Logger::DEBUG
      MarketData::CoinbaseFuturesSubscriber.new(product_ids: products, logger: stdout_logger).start
    else
      MarketDataSubscribeJob.perform_later(products)
      puts "Enqueued MarketDataSubscribeJob for: #{products.join(",")}"
    end
  end

  desc "Fetch and upsert futures products from Advanced Trade API"
  task upsert_futures_products: :environment do
    rest = MarketData::CoinbaseRest.new
    puts "Fetching futures products from Advanced Trade API..."
    rest.upsert_products
    puts "Completed upserting futures products"
  end

  desc "Backfill BTC-USD 1h candles"
  task :backfill_candles, [ :days ] => :environment do |_t, args|
    days = (args[:days] || 30).to_i
    FetchCandlesJob.perform_later(backfill_days: days)
  end

  desc "Backfill BTC-USD 1h candles (direct API)"
  task :backfill_1h_candles, [ :days ] => :environment do |_t, args|
    days = (args[:days] || 30).to_i
    rest = MarketData::CoinbaseRest.new

    btc_pair = TradingPair.find_by(product_id: "BTC-USD")

    unless btc_pair
      puts "No BTC trading pair found. Run 'rake market_data:upsert_futures_products' first."
      next
    end

    start_time = days.days.ago
    end_time = Time.now.utc

    puts "Backfilling 1h candles for #{btc_pair.product_id} from #{start_time} to #{end_time}"
    puts "This will fetch approximately #{days * 24} candles..."

    rest.upsert_1h_candles(product_id: btc_pair.product_id, start_time: start_time, end_time: end_time)

    # Count what we got
    count = Candle.where(symbol: btc_pair.product_id, timeframe: "1h").count
    puts "Completed! Total 1h candles in database: #{count}"
  end

  desc "Backfill BTC-USD 30m candles"
  task :backfill_30m_candles, [ :days ] => :environment do |_t, args|
    days = (args[:days] || 7).to_i
    rest = MarketData::CoinbaseRest.new

    # Use existing BTC-USD product for now (spot trading)
    # TODO: Research correct futures API endpoints for BTC-USD-PERP
    btc_pair = TradingPair.find_by(product_id: "BTC-USD")

    unless btc_pair
      puts "No BTC trading pair found. Run 'rake market_data:upsert_futures_products' first."
      next
    end

    start_time = days.days.ago
    end_time = Time.now.utc

    puts "Fetching 30m candles for #{btc_pair.product_id} from #{start_time} to #{end_time}"
    rest.upsert_30m_candles(product_id: btc_pair.product_id, start_time: start_time, end_time: end_time)
    puts "Completed fetching 30m candles"
  end

  desc "Test 1h candles (should work with most APIs)"
  task :test_1h_candles, [ :days ] => :environment do |_t, args|
    days = (args[:days] || 1).to_i
    rest = MarketData::CoinbaseRest.new

    btc_pair = TradingPair.find_by(product_id: "BTC-USD")

    unless btc_pair
      puts "No BTC trading pair found. Run 'rake market_data:upsert_futures_products' first."
      next
    end

    start_time = days.days.ago
    end_time = Time.now.utc

    puts "Testing 1h candles for #{btc_pair.product_id} from #{start_time} to #{end_time}"
    rest.upsert_1h_candles(product_id: btc_pair.product_id, start_time: start_time, end_time: end_time)
    puts "Completed testing 1h candles"
  end

  desc "Test different candle granularities to see what the API supports"
  task test_granularities: :environment do
    rest = MarketData::CoinbaseRest.new
    btc_pair = TradingPair.find_by(product_id: "BTC-USD")

    unless btc_pair
      puts "No BTC trading pair found. Run 'rake market_data:upsert_futures_products' first."
      next
    end

    # Test common granularities (in seconds)
    granularities = {
      "1m" => 60,
      "5m" => 300,
      "15m" => 900,
      "30m" => 1800,
      "1h" => 3600,
      "6h" => 21600,
      "1d" => 86400
    }

    start_time = 1.day.ago
    end_time = Time.now.utc

    puts "Testing different granularities for #{btc_pair.product_id} from #{start_time} to #{end_time}"

    granularities.each do |name, seconds|
      puts "Testing #{name} (#{seconds}s)..."
      begin
        data = rest.fetch_candles(
          product_id: btc_pair.product_id,
          start_iso8601: start_time.iso8601,
          end_iso8601: end_time.iso8601,
          granularity: seconds
        )
        puts "  ✓ #{name}: Got #{data.count} candles"
      rescue => e
        puts "  ✗ #{name}: #{e.class} - #{e.message}"
      end
    end
  end
end
