# frozen_string_literal: true

module Trading
  # Paper-default execution gate (issue #352). Live trading is opt-in only:
  # unless the operator sets LIVE_TRADING_CONFIRMED=1, dry-run is forced ON
  # before any order flow. Called from every entry path (launcher, realtime
  # session) AND at the order chokepoint (CoinbasePositions#submit_order) so
  # no path can send real orders without explicit confirmation.
  module ExecutionSafety
    module_function

    # Returns :live (confirmed), :paper (dry-run already on), or
    # :forced_paper (dry-run was off without confirmation — now forced on).
    def enforce_paper_default!(logger: Rails.logger)
      return :live if ENV["LIVE_TRADING_CONFIRMED"] == "1"
      return :paper if DryRun.active?

      logger.warn("[ExecutionSafety] Live trading not confirmed — forcing DRY-RUN. " \
                  "Set LIVE_TRADING_CONFIRMED=1 and disable dry-run to trade live.")
      DryRun.enable!(logger: logger)
      :forced_paper
    end
  end
end
