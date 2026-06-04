# frozen_string_literal: true

require "gum"

module Tui
  module Forms
    class HaltToggle
      def self.run
        halted = TradingHalt.halted?
        action = halted ? "RESUME trading" : "HALT trading"
        confirmed = Gum.confirm("#{action}?", affirmative: action, negative: "Cancel")
        return unless confirmed

        if halted
          TradingHalt.resume!
          Gum.log("Trading RESUMED", level: "info")
        else
          reason = Gum.input(header: "Halt reason (optional)", placeholder: "Leave blank to skip")
          TradingHalt.halt!(reason: reason.presence)
          msg = reason.present? ? "Trading HALTED — #{reason}" : "Trading HALTED"
          Gum.log(msg, level: "warn")
        end
      rescue => e
        Gum.log("Halt error: #{e.message}", level: "error")
      end
    end
  end
end
