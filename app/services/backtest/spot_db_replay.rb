# frozen_string_literal: true

module Backtest
  class SpotDbReplay
    def initialize(product_id:, strategy:, start_time:, end_time:, logger: Rails.logger)
      @product_id = product_id
      @strategy = strategy
      @start_time = Time.parse(start_time)
      @end_time = Time.parse(end_time)
      @logger = logger
    end

    def run
      count = 0
      Tick.for_product(@product_id).between(@start_time, @end_time).order(:observed_at).find_each(batch_size: 1000) do |tick|
        @strategy.on_ticker({
          "product_id" => tick.product_id,
          "price" => tick.price.to_s,
          "time" => tick.observed_at.iso8601
        })
        count += 1
      end
      @logger.info("[BT-DB] replay complete: #{count} ticks")
    end
  end
end
