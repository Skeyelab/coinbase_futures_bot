# frozen_string_literal: true

namespace :market_data do
  desc "Subscribe to Coinbase futures ticker (GoodJob async)"
  task :subscribe, [:products] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD").split(",")

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

  desc "Backfill candles for enabled contracts (issue #342). Usage: market_data:backfill[60] or market_data:backfill[60,'BTC-USD ETH-USD NOL-19AUG26-CDE']"
  task :backfill, [:days, :products, :max_1m_days, :async] => :environment do |_t, args|
    days = (args[:days] || ENV["BACKFILL_DAYS"] || 30).to_i
    products = (args[:products] || ENV["PRODUCTS"]).to_s.split(/[\s,]+/).reject(&:empty?)
    symbols = products.presence
    max_1m_days = args[:max_1m_days]&.to_i

    if args[:async].present?
      # Long backfills belong on the worker's low queue (1 thread) so cron
      # and realtime jobs are unaffected; GoodJob owns retries/visibility.
      FetchCandlesJob.set(queue: :low).perform_later(backfill_days: days, symbols: symbols, max_1m_days: max_1m_days)
      puts "Enqueued backfill (#{days}d, #{symbols&.join(", ") || "ALL enabled contracts"}) on the low queue"
      next
    end

    puts "Backfilling #{days}d of candles for #{symbols&.join(", ") || "ALL enabled contracts"} (inline)"
    FetchCandlesJob.perform_now(backfill_days: days, symbols: symbols, max_1m_days: max_1m_days)
    puts "Done. Candle depth:"
    (symbols || Contract.enabled.pluck(:product_id)).each do |sym|
      %w[1m 5m 15m 1h].each do |tf|
        scope = Candle.where(symbol: sym, timeframe: tf)
        puts "  #{sym} #{tf}: #{scope.count} candles (from #{scope.minimum(:timestamp)&.to_date})"
      end
    end
  end

  desc "Enqueue background candle backfill for all enabled contracts"
  task :backfill_candles, [:days] => :environment do |_t, args|
    days = (args[:days] || 30).to_i
    FetchCandlesJob.perform_later(backfill_days: days)
  end

  desc "Test different candle granularities to see what the API supports"
  task test_granularities: :environment do
    rest = MarketData::CoinbaseRest.new
    btc_pair = Contract.find_by(product_id: "BTC-USD")

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
      "6h" => 21_600,
      "1d" => 86_400
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
  task :subscribe_futures, [:products] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD").split(",")

    if ENV["INLINE"].to_s == "1"
      puts "Running inline futures subscription for: #{products.join(",")}"
      stdout_logger = Logger.new($stdout)
      stdout_logger.level = Logger::DEBUG
      MarketData::CoinbaseDerivativesSubscriber.new(product_ids: products, logger: stdout_logger).start
    else
      puts "Futures subscription currently supports INLINE=1 only (no job enqueuing yet)"
    end
  end

  desc "Persist live spot ticks to DB (Tick) for backtesting"
  task :ingest_spot_to_db, [:spot_product] => :environment do |_t, args|
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

    MarketData::CoinbaseSpotSubscriber.new(product_ids: [spot], logger: stdout_logger, on_ticker: on_ticker).start
  end
end
