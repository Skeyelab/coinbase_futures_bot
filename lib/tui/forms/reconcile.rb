# frozen_string_literal: true

require "gum"

module Tui
  module Forms
    class Reconcile
      def self.run
        confirmed = Gum.confirm("Close local OPEN rows missing from Coinbase?", affirmative: "Reconcile", negative: "Cancel")
        return unless confirmed

        svc = PositionReconcileService.new
        result = svc.reconcile!
        msg = "Reconciled #{result[:closed_count]} local row(s)"
        msg += " — #{result[:errors].join("; ")}" if result[:errors].any?
        level = result[:errors].any? ? "warn" : "info"
        Gum.log(msg, level: level)
      rescue => e
        Gum.log("Reconcile error: #{e.message}", level: "error")
      end
    end
  end
end
