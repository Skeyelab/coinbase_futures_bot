# frozen_string_literal: true

module Trading
  # One place that answers "how is the paper account doing over a window".
  #
  # Extracted from DailySummaryJob because a SECOND, worse answer had grown in
  # Trading::PositionManagement::DayTradingWorkflow: its Slack "PnL Update" card
  # passed `daily_pnl: nil` and `win_rate: nil` as literals, and sourced
  # "Total PnL" from unrealized PnL on OPEN positions only. On 2026-07-28 that
  # card reported "Total PnL $0 / Daily PnL $ / Win Rate N/A" on a day the paper
  # account had closed five trades for +$62.65 — every number an operator would
  # act on was absent or wrong, while the daily summary job computed all of them
  # correctly an hour earlier.
  #
  # That is the duplication ADR 0007 and #290 exist to stop: two routers over
  # the same reads, drifting until one of them lies. There is now one.
  class PaperPnlSummary
    def self.call(since:, now: Time.current) = new(since: since, now: now).call

    def initialize(since:, now: Time.current)
      @since = since
      @now = now
    end

    def call
      closed = closed_positions
      wins = closed.count { |p| p.pnl.to_f > 0 }
      maes = closed.filter_map { |p| p.max_adverse_excursion&.to_f }
      holds = closed.filter_map(&:holding_seconds)

      {
        trades: closed.size,
        wins: wins,
        win_rate: closed.any? ? (wins.to_f / closed.size * 100).round(1) : 0.0,
        realized_pnl: closed.sum { |p| p.pnl.to_f }.round(2),
        avg_mae: maes.any? ? (maes.sum / maes.size).round(2) : nil,
        worst_mae: maes.min&.round(2),
        avg_hold_min: holds.any? ? (holds.sum.to_f / holds.size / 60).round(1) : nil,
        open: Position.open.count,
        unrealized_pnl: unrealized_pnl,
        equity: PaperAccount.new.equity.round(2)
      }.merge(cost_metrics(closed, wins))
    end

    private

    attr_reader :since, :now

    def closed_positions
      Position.closed.where(paper: true).where("close_time >= ?", since).to_a
    end

    # Open-position PnL, kept SEPARATE from realized rather than summed into a
    # field called "total". Conflating them is what let the PnL card show $0 on
    # a profitable day: with nothing open, unrealized is legitimately zero, and
    # labelling that "Total PnL" hides every trade that already closed.
    def unrealized_pnl
      Position.open.sum { |p| p.pnl.to_f }.round(2)
    end

    # Issue #353: the paper sim's recorded PnL is price-move only, so estimate
    # taker round-trip costs (fees on both sides' contract-size notional) and
    # gate on positive expectancy NET of those costs.
    def cost_metrics(closed, wins)
      costed = closed.select { |p| p.entry_price }
      total_cost = costed.sum { |p| round_trip_cost_for(p) }

      avg_win = if wins.positive?
        closed.select { |p| p.pnl.to_f > 0 }.sum { |p| p.pnl.to_f } / wins
      end
      cost_per_rt = costed.any? ? (total_cost / costed.size).round(2) : nil
      net = closed.any? ? (closed.sum { |p| p.pnl.to_f } - total_cost).round(2) : nil

      {
        cost_per_round_trip: cost_per_rt,
        cost_pct_of_avg_win: (cost_per_rt && avg_win&.positive?) ? (cost_per_rt / avg_win * 100).round(1) : nil,
        net_of_costs: net,
        cost_gate_passed: net.nil? ? nil : net > 0
      }
    end

    # Prefer ACTUAL recorded fill fees (issue #372) over the estimate; estimate
    # applies the flat per-contract floor. Exit price isn't recorded on
    # Position, so estimated exit notional approximates with entry — the price
    # move is noise relative to notional for fee purposes.
    def round_trip_cost_for(position)
      actual = position.entry_fee.to_f + position.exit_fee.to_f
      return actual if position.entry_fee && position.exit_fee

      notional_price = position.entry_price.to_f * contract_size(position.product_id)
      # Per-venue (issue #459): a dated position pays its own rate and floor.
      CostModel.round_trip_cost_for(
        symbol: position.product_id,
        entry_price: notional_price,
        exit_price: notional_price,
        quantity: position.size.to_f,
        contracts: position.size.to_f
      )
    end

    def contract_size(product_id) = Trading::ContractSizeResolver.for_product(product_id)
  end
end
