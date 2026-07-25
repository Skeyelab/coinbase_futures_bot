# frozen_string_literal: true

module Trading
  # The ACTUAL account equity, for the MaxDrawdown guard (issue #451). It must
  # move with PnL or the equity circuit breaker can never breach — the bug this
  # fixes was feeding the guard SignalEquity.usd (a static sizing constant), so
  # its peak never moved. Paper equity in dry-run; the live CFM account balance
  # otherwise. Falls back to the sizing figure if the live balance can't be read,
  # so the guard degrades safely instead of crashing the eval cycle.
  #
  # Distinct from SignalEquity (issue #375), which is the fixed notional used for
  # position SIZING and must stay constant.
  module CurrentEquity
    module_function

    def usd(client: nil)
      return PaperAccount.new.equity if DryRun.active?

      live_usd(client) || SignalEquity.usd
    end

    def live_usd(client)
      client ||= Coinbase::Client.new
      value = client.futures_balance_summary.to_h["total_usd_balance"].to_f
      value.positive? ? value : nil
    rescue => e
      Rails.logger.warn("[CurrentEquity] live balance unavailable, falling back to SignalEquity: #{e.class}: #{e.message}")
      nil
    end
  end
end
