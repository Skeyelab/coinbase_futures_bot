# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # Issue #486's blocking preconditions, asserted in code before a single
    # order is placed. Every one of them is checkable, so every one of them is
    # checked — the alternative is a checklist in an issue, which is what the
    # #396-#401 protections turned out to be.
    #
    # Collects ALL failures rather than raising on the first: an operator who
    # has to discover four missing preconditions across four aborted runs will
    # start skipping the check.
    class Preflight
      # #486 authorizes $150 of loss for the whole program. The cumulative cap
      # must be at or below that, never above — a $500 cap would not stop the
      # run at the authorized number. Asserted rather than assumed, because
      # LOSS_CAP_CUMULATIVE_USD is an env var anyone can change.
      AUTHORIZED_LOSS_USD = 150.0

      def initialize(product_id:, logger: Rails.logger)
        @product_id = product_id
        @logger = logger
      end

      def satisfied? = failures.empty?

      def failures
        @failures ||= [
          risk_halt_available,
          cumulative_loss_cap_wired,
          equity_assertion_passes,
          contract_pinned_to_one,
          nothing_already_open,
          trading_not_halted
        ].compact
      end

      # Logs the refusal loudly, naming each unmet precondition.
      def refuse!
        @logger.error("[ExecutionCalibration] REFUSING TO START — #{failures.size} precondition(s) unmet " \
                      "for #{@product_id} (issue #486):")
        failures.each { |f| @logger.error("[ExecutionCalibration]   - #{f}") }
        failures
      end

      private

      # Precondition 1: a NON-EXPIRING risk halt exists. An operational halt
      # auto-expires after a TTL, which would silently re-permit trading after
      # an abort — the abort conditions below are worthless without this.
      def risk_halt_available
        return nil if TradingHalt.respond_to?(:halt_for_risk!) && TradingHalt.respond_to?(:risk_halted?)

        "precondition 1: no non-expiring risk halt available — TradingHalt.halt_for_risk! is missing, " \
          "so an abort could not stop the run in a way that survives a TTL (issue #481)"
      end

      # Precondition 2: the cumulative-loss counter is wired to that halt, and
      # its cap is at or under the authorized loss.
      def cumulative_loss_cap_wired
        cap = Trading::LossLimits.cumulative_cap.to_f
        return nil if cap.positive? && cap <= AUTHORIZED_LOSS_USD

        "precondition 2: cumulative loss cap is #{format("$%.2f", cap)} — must be positive and at or below " \
          "the #{format("$%.0f", AUTHORIZED_LOSS_USD)} authorized for this run. " \
          "Set LOSS_CAP_CUMULATIVE_USD (issue #482, #392 condition 3)"
      end

      # Precondition 3: SIGNAL_EQUITY_USD agrees with the real balance.
      def equity_assertion_passes
        Trading::EquityAssertion.verify!(logger: @logger)
        nil
      rescue Trading::EquityAssertion::Divergence => e
        "precondition 3: equity assertion failed — #{e.message}"
      rescue => e
        "precondition 3: equity assertion could not run — #{e.class}: #{e.message}"
      end

      # Precondition 4: the instrument is pinned to one contract and one
      # concurrent position (config/asset_sizing.yml `contracts:` block).
      def contract_pinned_to_one
        params = Trading::AssetSizing.for_product(@product_id)
        problems = []
        problems << "max_contracts=#{params.max_contracts}" unless params.max_contracts == 1
        problems << "max_concurrent=#{params.max_concurrent}" unless params.max_concurrent == 1
        return nil if problems.empty?

        "precondition 4: #{@product_id} is not pinned to a single contract (#{problems.join(", ")}) — " \
          "pin it under `contracts:` in config/asset_sizing.yml"
      end

      # Not one of #486's four, but the run cannot be idempotent without it: an
      # already-open position would be closed by this run's exit leg and
      # misattributed to a calibration round trip.
      def nothing_already_open
        open = Position.open.by_product(@product_id).count
        return nil if open.zero?

        "#{open} position(s) already OPEN on #{@product_id} — close them first; " \
          "this run must start flat so every fill it measures is one it placed"
      end

      def trading_not_halted
        return nil if TradingHalt.active?

        status = TradingHalt.status
        "trading is halted (#{status[:kind] || "unknown"}: #{status[:reason] || "no reason recorded"}) — " \
          "clear it deliberately before starting a run that places orders"
      end
    end
  end
end
