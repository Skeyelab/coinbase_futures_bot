# frozen_string_literal: true

module Trading
  module ExecutionCalibration
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
  end
end
