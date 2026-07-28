# frozen_string_literal: true

module Trading
  # Execution calibration (issue #486): 20 forced BIP round trips, one contract
  # each, to measure the real perp taker rate, maker fill rate, slippage and
  # funding.
  #
  # ADR 0002 made perps the primary venue on the strength of a ~3 bps taker rate
  # taken from a published schedule. No perp order has ever been filled, so the
  # number that flipped the strategy's unit economics from -9 bps to +15 bps has
  # never been checked against reality. This buys that measurement, and nothing
  # else: no edge may be inferred from 20 forced trades.
  #
  # Entry point: Trading::ExecutionCalibration::Runner. Exposed to operators as
  # `bin/futuresbot calibrate`.
  module ExecutionCalibration
    module_function

    # The BIP contract this run targets. Resolved from ingested contracts rather
    # than hardcoded with an expiry, because a perp's product id carries a dummy
    # 2030 expiry that will change if Coinbase reissues it.
    def default_product_id
      Contract.enabled.where("product_id LIKE ?", "#{Runner::INSTRUMENT_PREFIX}-%")
        .order(:product_id).first&.product_id
    end
  end
end
