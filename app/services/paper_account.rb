# frozen_string_literal: true

# PaperAccount is a read-only view of simulated ("paper") trading state built
# from persisted paper Positions (see DryRun / #300). Equity is the configured
# starting balance plus realized PnL from closed paper positions plus the
# mark-to-market unrealized PnL of open ones. Because it derives from the
# positions table, the state is durable and shared across processes.
class PaperAccount
  DEFAULT_STARTING_EQUITY = 10_000.0

  def self.starting_equity
    ENV.fetch("PAPER_EQUITY_USD", DEFAULT_STARTING_EQUITY).to_f
  end

  def open_positions
    Position.where(paper: true, status: "OPEN")
  end

  def realized_pnl
    Position.where(paper: true, status: "CLOSED").sum(:pnl).to_f
  end

  def unrealized_pnl
    open_positions.sum do |position|
      price = RecentMarketPrice.for_product(position.product_id)
      price ? (position.unrealized_pnl_at(price) || 0.0) : 0.0
    end
  end

  def equity
    self.class.starting_equity + realized_pnl + unrealized_pnl
  end

  def any?
    Position.where(paper: true).exists?
  end
end
