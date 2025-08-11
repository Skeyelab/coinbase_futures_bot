# frozen_string_literal: true

module Strategy
  # Minimal spot-driven strategy: forwards spot ticks to an executor
  # with basis/liquidity guardrails handled by the executor.
  class SpotDrivenStrategy
    def initialize(spot_product_id:, futures_product_id:, executor:, logger: Rails.logger)
      @spot_product_id = spot_product_id
      @futures_product_id = futures_product_id
      @executor = executor
      @logger = logger
    end

    def on_ticker(tick)
      return unless tick["product_id"] == @spot_product_id

      price = tick["price"].to_f
      time = tick["time"]

      # Placeholder signal: echo tick through to executor
      @logger.debug("[STRAT] spot tick #{price} @ #{time}")
      @executor.consider_entry(spot_price: price, futures_product_id: @futures_product_id, at: time)
    end
  end
end
