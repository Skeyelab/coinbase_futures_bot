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

        svc = Trading::CoinbasePositions.new(logger: Rails.logger)
        result = svc.close_position(product_id: position.product_id, size: position.size)
        if result["success"] || result["order_id"]
          Gum.log("Close submitted for ##{position.id}", level: "info")
        else
          Gum.log("Close failed: #{result.inspect}", level: "error")
        end
      rescue => e
        Gum.log("Close error: #{e.message}", level: "error")
      end
    end
  end
end
