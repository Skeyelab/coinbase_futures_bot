# frozen_string_literal: true

namespace :market_data do
  desc "Subscribe to Coinbase futures ticker (GoodJob async)"
  task :subscribe, [ :products ] => :environment do |_t, args|
    products = (args[:products] || ENV["PRODUCT_IDS"] || "BTC-USD-PERP").split(",")
    MarketDataSubscribeJob.perform_later(products)
    puts "Enqueued MarketDataSubscribeJob for: #{products.join(",")}"
  end
end
