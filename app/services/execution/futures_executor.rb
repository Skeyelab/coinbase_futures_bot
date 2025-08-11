# frozen_string_literal: true

module Execution
  class FuturesExecutor
    def initialize(basis_threshold_bps: ENV.fetch("BASIS_THRESHOLD_BPS", 50).to_i, logger: Rails.logger)
      @basis_threshold_bps = basis_threshold_bps
      @logger = logger
    end

    # spot_price: Float
    # futures_product_id: String
    # at: ISO8601 String
    def consider_entry(spot_price:, futures_product_id:, at: Time.now.utc.iso8601)
      # TODO: Query futures best bid/ask or mark via REST to compute basis
      # For now, just log the intent and apply a placeholder basis check
      futures_mark = spot_price # placeholder assumption until wired
      basis_bps = ((futures_mark - spot_price) / spot_price.to_f) * 10_000

      if basis_bps.abs > @basis_threshold_bps
        @logger.info("[EXEC] skip: basis #{basis_bps.round(2)}bps > #{@basis_threshold_bps}bps")
        return
      end

      @logger.info("[EXEC] would place order on #{futures_product_id} at spot=#{spot_price} (basis=#{basis_bps.round(2)}bps) @ #{at}")
    end
  end
end
