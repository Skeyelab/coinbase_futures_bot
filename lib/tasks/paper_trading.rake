# frozen_string_literal: true

namespace :paper do
  desc "Run one paper trading step for BTC-USD 1h"
  task :step => :environment do
    PaperTradingJob.perform_now
  end

  desc "Run calibration over recent history"
  task :calibrate => :environment do
    CalibrationJob.perform_now
  end
end

namespace :market_data do
  desc "Subscribe to Coinbase spot ticker (GoodJob async)"
  task :subscribe_spot, [ :products ] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD").split(",")

    if ENV["INLINE"].to_s == "1"
      stdout_logger = Logger.new($stdout)
      stdout_logger.level = Logger::DEBUG
      MarketData::CoinbaseSpotSubscriber.new(product_ids: products, logger: stdout_logger).start
    else
      MarketDataSubscribeJob.perform_later(products)
      puts "Enqueued MarketDataSubscribeJob for: #{products.join(",")}"
    end
  end
end