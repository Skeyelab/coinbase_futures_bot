# frozen_string_literal: true

require "csv"

module Backtest
  # Replays spot ticks from a CSV to a strategy's on_ticker callback.
  # Expected CSV headers: time (ISO8601), price (Float), optional product_id.
  class SpotCsvReplay
    def initialize(csv_path:, product_id:, strategy:, logger: Rails.logger)
      @csv_path = csv_path
      @product_id = product_id
      @strategy = strategy
      @logger = logger
    end

    def run
      count = 0
      CSV.foreach(@csv_path, headers: true) do |row|
        tick = {
          "product_id" => row["product_id"] || @product_id,
          "price" => row["price"],
          "time" => row["time"]
        }
        @strategy.on_ticker(tick)
        count += 1
      end
      @logger.info("[BT] replay complete: #{count} ticks")
    end
  end
end


