# frozen_string_literal: true

module Trading
  module ExecutionCalibration
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

      # nil, not 0.0, when no leg carries a debited figure. Nothing in the
      # codebase ever ASSIGNS Leg#funding_debited — funding is charged out of
      # band by the venue and never appears on the order path this run reads.
      # Summing nils to 0.0 turned that absence into "$0.0000 debited", which
      # reads as a measurement of zero rather than an absence of measurement,
      # and made the report's "not observable" branch dead code.
      def funding_debited
        observed = legs.filter_map(&:funding_debited)
        return nil if observed.empty?

        observed.sum(&:to_f)
      end

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
