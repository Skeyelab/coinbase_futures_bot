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

  # Scoped to the MODE IN FORCE, not to paper (ADR 0006). This filtered
  # `paper: true`, and with LIVE_TRADING_CONFIRMED=1 positions are written
  # `paper: false` — so the only automated writer of Trading::SymbolSuspension
  # queried an empty set and suspended nothing, on exactly the runs where a
  # cost-bleeding symbol costs real money. Trading::LossLimits already scopes
  # this way; the breaker now matches it, so the caps can be drilled in paper
  # and still mean real dollars live.
  def perform(window: TRAILING_WINDOW, min_trades: MIN_TRADES)
    closed = Position.closed.where(paper: DryRun.active?).where("close_time >= ?", window.ago)

    closed.group_by(&:product_id).each do |symbol, trades|
      # Distinct POSITIONS, not distinct rows. Since #509 a partial reduce
      # creates its own CLOSED row, so five reduces of one position satisfied a
      # five-TRADE minimum — the breaker would suspend a symbol on a sample of
      # one. parent_position_id is NULL for a whole trade, which is why it
      # coalesces to the row's own id.
      next if distinct_positions(trades) < min_trades
      next if Trading::SymbolSuspension.explicitly_suspended?(symbol)

      gross = trades.sum { |p| p.pnl.to_f }
      costs = trades.sum { |t| estimated_round_trip_cost(t) }
      next if gross >= costs

      Trading::SymbolSuspension.suspend!(
        symbol,
        reason: "trailing #{distinct_positions(trades)}-trade gross $#{gross.round(2)} < est. costs $#{costs.round(2)} over #{(window / 1.day).to_i}d"
      )
    end
  end

  private

  # How many POSITIONS these rows represent. Costs are still summed per row —
  # each slice paid its own exit fee — but the SAMPLE is positions, because that
  # is the unit MIN_TRADES is a statement about.
  def distinct_positions(trades)
    trades.map { |t| t.parent_position_id || t.id }.uniq.size
  end

  # Same cost model as DailySummaryJob: taker fees on both sides of the
  # contract-size notional; exit approximated by entry (not recorded).
  #
  # Priced at the POSITION's venue (issue #459). Using the global perp rate here
  # understated every dated position, so the breaker needed a bigger loss before
  # it would trip on exactly the contracts whose costs are highest.
  def estimated_round_trip_cost(position)
    notional_price = position.entry_price.to_f *
      Trading::ContractSizeResolver.for_product(position.product_id).to_f
    CostModel.round_trip_cost_for(
      symbol: position.product_id,
      entry_price: notional_price,
      exit_price: notional_price,
      quantity: position.size.to_f,
      contracts: position.size.to_f
    )
  end
end
