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

      def buying? = %w[BUY LONG].include?(side.to_s.upcase)
    end

    # One forced round trip: an entry, a hold, an exit. `entry` is nil when a
    # maker entry never filled — the observation #486 exists to collect.
    Leg = Struct.new(
      :number, :intent, :entry, :exit, :intended_hold_seconds, :held_seconds,
      :realized_pnl, :error, :position_id, :funding_debited, :funding_modeled
    ) do
      def fills = [entry, exit].compact

      def maker_intent? = intent.to_s.to_sym == :maker

      def entry_filled? = !entry.nil?

      def maker_filled? = maker_intent? && entry&.maker?
    end

    # The accumulated observations of one calibration run. Pure accounting: it
    # decides nothing and halts nothing, so both the abort conditions and the
    # final report read the same numbers.
    class Tape
      attr_reader :product_id, :legs

      def initialize(product_id:, legs: [])
        @product_id = product_id
        @legs = legs
      end

      def add(leg)
        @legs << leg
        leg
      end

      def fills = legs.flat_map(&:fills)

      def taker_fills = fills.select(&:taker?)

      def maker_attempts = legs.select(&:maker_intent?)

      def maker_fills = legs.select(&:maker_filled?)

      def taker_attempts = legs.reject(&:maker_intent?)

      def completed = legs.count { |l| l.error.nil? && l.entry_filled? }

      # Commission-weighted, not an average of per-fill rates: one fill on a
      # small notional would otherwise drag the mean around.
      def measured_taker_rate = weighted_rate(taker_fills)

      def measured_maker_rate = weighted_rate(fills.select(&:maker?))

      # nil, not 0.0, when no maker entry was attempted — "not measured" and
      # "never filled" are different findings and #486 turns on which it is.
      def maker_fill_rate
        return nil if maker_attempts.empty?

        maker_fills.size.to_f / maker_attempts.size
      end

      def realized_pnl = legs.sum { |l| l.realized_pnl.to_f }

      def total_commission = fills.sum { |f| f.commission.to_f }

      def funding_debited = legs.sum { |l| l.funding_debited.to_f }

      def funding_modeled = legs.sum { |l| l.funding_modeled.to_f }

      def slippage_bps = fills.map(&:slippage_bps)

      def worst_slippage_bps = fills.map(&:deviation_bps).max

      def duplicate_order_ids
        ids = fills.map(&:order_id).compact
        ids.tally.select { |_, count| count > 1 }.keys
      end

      # Every fill this run placed should be exactly one contract — that is the
      # whole sizing control (#486 precondition 4, #392 condition 1).
      def mis_sized_fills = fills.reject { |f| (f.contracts.to_f - 1.0).abs < 1e-9 }

      def rejected_legs = legs.select { |l| l.error.present? }

      def overrun_legs
        legs.select do |l|
          l.intended_hold_seconds.to_f.positive? &&
            l.held_seconds.to_f > l.intended_hold_seconds.to_f * HOLD_OVERRUN_MULTIPLE
        end
      end

      HOLD_OVERRUN_MULTIPLE = 2.0

      private

      def weighted_rate(selected)
        notional = selected.sum(&:notional)
        return nil unless notional.positive?

        selected.sum { |f| f.commission.to_f } / notional
      end
    end
  end
end
