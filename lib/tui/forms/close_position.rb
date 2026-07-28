# frozen_string_literal: true

require "gum"

module Tui
  module Forms
    class ClosePosition
      def self.run(id_str)
        id_str = id_str.to_s.strip
        return if id_str.empty?
        unless id_str.match?(/\A\d+\z/)
          Gum.log("Invalid position id: #{id_str}", level: "error")
          return
        end
        position = Position.find_by(id: id_str.to_i, status: "OPEN")
        unless position
          Gum.log("No OPEN position ##{id_str}", level: "error")
          return
        end
        confirmed = Gum.confirm("Close #{position.product_id} ##{position.id}?", affirmative: "Close", negative: "Cancel")
        return unless confirmed

        # Route through PositionLifecycle, not CoinbasePositions directly: an
        # operator close is still an exit and must feed the protections layer
        # (cooldown, stoploss guard, daily loss caps — ADR 0003). Closing through
        # the executor bypassed all three, so a loser closed by hand never
        # counted against the caps that exist to stop the next one.
        svc = Trading::CoinbasePositions.new(logger: Rails.logger)
        outcome = Trading::PositionLifecycle
          .new(positions_service: svc, logger: Rails.logger)
          .close(position, reason: "tui_operator_close")

        if outcome.success?
          Gum.log("Closed ##{position.id} at #{outcome.close_price}", level: "info")
        else
          Gum.log("Close failed for ##{position.id}; left OPEN", level: "error")
        end
      rescue => e
        Gum.log("Close error: #{e.message}", level: "error")
      end
    end
  end
end
