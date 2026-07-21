# frozen_string_literal: true

module Trading
  # Single source of truth for the equity figure used in signal sizing
  # (issue #375): the executor path defaulted to $50k while every analysis
  # path defaulted to $10k — a silent 5x sizing skew when SIGNAL_EQUITY_USD
  # was unset. $10k matches the paper account and the operator's thesis.
  module SignalEquity
    module_function

    def usd
      ENV.fetch("SIGNAL_EQUITY_USD", "10000").to_f
    end
  end
end
