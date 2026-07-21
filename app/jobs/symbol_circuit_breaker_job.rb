# frozen_string_literal: true

# Per-symbol cost-efficiency circuit breaker (issue #371): suspends any
# symbol whose trailing realized gross PnL fails to cover its estimated
# taker round-trip costs — the cheapest fee is the trade never placed.
# Realized-PnL complement to the ex-ante net-of-costs gate (#358).
# Suspension only blocks new entries (exits continue); resume is manual —
# a symbol re-earns its slot, it doesn't drift back in.
class SymbolCircuitBreakerJob < ApplicationJob
  queue_as :default

  TRAILING_WINDOW = 7.days
  MIN_TRADES = 5

  def perform(window: TRAILING_WINDOW, min_trades: MIN_TRADES)
    closed = Position.closed.where(paper: true).where("close_time >= ?", window.ago)

    closed.group_by(&:product_id).each do |symbol, trades|
      next if trades.size < min_trades
      next if Trading::SymbolSuspension.suspended?(symbol)

      gross = trades.sum { |p| p.pnl.to_f }
      costs = trades.sum { |t| estimated_round_trip_cost(t) }
      next if gross >= costs

      Trading::SymbolSuspension.suspend!(
        symbol,
        reason: "trailing #{trades.size}-trade gross $#{gross.round(2)} < est. costs $#{costs.round(2)} over #{(window / 1.day).to_i}d"
      )
    end
  end

  private

  # Same cost model as DailySummaryJob: taker fees on both sides of the
  # contract-size notional; exit approximated by entry (not recorded).
  def estimated_round_trip_cost(position)
    notional_price = position.entry_price.to_f *
      Trading::ContractSizeResolver.for_product(position.product_id).to_f
    CostModel.round_trip_cost(
      entry_price: notional_price,
      exit_price: notional_price,
      quantity: position.size.to_f,
      fee_rate: CostModel.taker_fee_rate,
      contracts: position.size.to_f
    )
  end
end
