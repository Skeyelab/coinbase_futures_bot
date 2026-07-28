# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # One observed fill. `contracts` x `contract_multiplier` x `fill_price` is
    # the dollar notional the commission was charged against — the multiplier is
    # required because a perp `size` is in CONTRACTS, not coins, and dividing a
    # commission by a contract count would report a rate 100x wrong on a nano.
    Fill = Struct.new(
      :phase, :liquidity, :side, :order_id, :intended_price, :fill_price,
      :commission, :contracts, :contract_multiplier, :filled_at
    ) do
      def notional
        fill_price.to_f * contracts.to_f * (contract_multiplier.to_f.positive? ? contract_multiplier.to_f : 1.0)
      end

      def taker? = liquidity.to_s.upcase == "TAKER"

      def maker? = liquidity.to_s.upcase == "MAKER"

      def effective_rate
        notional.positive? ? commission.to_f / notional : nil
      end

      # Signed so that POSITIVE always means "worse for us": paying above the
      # intended price when buying, receiving below it when selling.
      def slippage_bps
        return 0.0 unless intended_price.to_f.positive?

        raw = (fill_price.to_f - intended_price.to_f) / intended_price.to_f * 10_000.0
        buying? ? raw : -raw
      end

      # Magnitude regardless of direction. A 25 bps FAVOURABLE deviation on a
      # forced 1-contract round trip is not a windfall, it means the reference
      # price this run measures slippage against was wrong — which invalidates
      # the measurement exactly as much as an adverse one.
      def deviation_bps = slippage_bps.abs

      def buying? = SideNormalizer.long?(side)
    end
  end
end
