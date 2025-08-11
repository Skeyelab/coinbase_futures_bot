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

  desc "Backfill BTC-USD 1h candles"
  task :backfill_candles, [ :days ] => :environment do |_t, args|
    days = (args[:days] || 30).to_i
    FetchCandlesJob.perform_now(backfill_days: days)
  end
end
