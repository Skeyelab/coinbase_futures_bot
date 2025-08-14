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

  desc "Backfill BTC-USD 15m candles"
  task :backfill_15m_candles, [ :days ] => :environment do |_t, args|
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

    puts "Fetching 15m candles for #{btc_pair.product_id} from #{start_time} to #{end_time}"
    rest.upsert_15m_candles(product_id: btc_pair.product_id, start_time: start_time, end_time: end_time)
    puts "Completed fetching 15m candles"
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

  desc "Subscribe to Coinbase futures (derivatives) ticker via futures WS"
  task :subscribe_futures, [ :products ] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD-PERP").split(",")

    if ENV["INLINE"].to_s == "1"
      puts "Running inline futures subscription for: #{products.join(",")}"
      stdout_logger = Logger.new($stdout)
      stdout_logger.level = Logger::DEBUG
      MarketData::CoinbaseDerivativesSubscriber.new(product_ids: products, logger: stdout_logger).start
    else
      puts "Futures subscription currently supports INLINE=1 only (no job enqueuing yet)"
    end
  end

  desc "Run spot-driven strategy: consume BTC-USD ticks and drive BTC-USD-PERP executor"
  task :run_spot_driven_strategy, [ :spot_product, :futures_product ] => :environment do |_t, args|
    spot = (args[:spot_product] || ENV["SPOT_PRODUCT"] || "BTC-USD").to_s
    perp = (args[:futures_product] || ENV["FUTURES_PRODUCT"] || "BTC-USD-PERP").to_s

    puts "Running spot-driven strategy: spot=#{spot} -> futures=#{perp}"
    stdout_logger = Logger.new($stdout)
    stdout_logger.level = Logger::DEBUG

    executor = Execution::FuturesExecutor.new(logger: stdout_logger)
    strategy = Strategy::SpotDrivenStrategy.new(
      spot_product_id: spot,
      futures_product_id: perp,
      executor: executor,
      logger: stdout_logger
    )

    on_ticker = ->(tick) { strategy.on_ticker(tick) }
    MarketData::CoinbaseSpotSubscriber.new(product_ids: [ spot ], logger: stdout_logger, on_ticker: on_ticker).start
  end


  desc "Persist live spot ticks to DB (Tick) for backtesting"
  task :ingest_spot_to_db, [ :spot_product ] => :environment do |_t, args|
    spot = (args[:spot_product] || ENV["SPOT_PRODUCT"] || "BTC-USD").to_s

    puts "Ingesting live ticks into DB for: #{spot}"
    stdout_logger = Logger.new($stdout)
    stdout_logger.level = Logger::INFO

    on_ticker = lambda do |tick|
      price_str = tick["price"]
      time_str = tick["time"]
      next if price_str.nil? || time_str.nil?

      Tick.create!(
        product_id: spot,
        price: price_str.to_d,
        observed_at: Time.parse(time_str)
      )
    rescue => e
      stdout_logger.error("[INGEST] failed to persist tick: #{e}")
    end

    MarketData::CoinbaseSpotSubscriber.new(product_ids: [ spot ], logger: stdout_logger, on_ticker: on_ticker).start
  end

  desc "Backtest spot-driven strategy from DB ticks"
  task :backtest_spot_db, [ :start_iso, :end_iso, :spot_product, :futures_product ] => :environment do |_t, args|
    start_iso = args[:start_iso] || ENV["START_ISO"]
    end_iso = args[:end_iso] || ENV["END_ISO"]
    raise ArgumentError, "start_iso and end_iso required" if start_iso.to_s.strip.empty? || end_iso.to_s.strip.empty?
    spot = (args[:spot_product] || ENV["SPOT_PRODUCT"] || "BTC-USD").to_s
    perp = (args[:futures_product] || ENV["FUTURES_PRODUCT"] || "BTC-USD-PERP").to_s

    stdout_logger = Logger.new($stdout)
    stdout_logger.level = Logger::INFO

    executor = Execution::FuturesExecutor.new(logger: stdout_logger)
    strategy = Strategy::SpotDrivenStrategy.new(
      spot_product_id: spot,
      futures_product_id: perp,
      executor: executor,
      logger: stdout_logger
    )

    Backtest::SpotDbReplay.new(product_id: spot, strategy: strategy, start_time: start_iso, end_time: end_iso, logger: stdout_logger).run
  end
end
