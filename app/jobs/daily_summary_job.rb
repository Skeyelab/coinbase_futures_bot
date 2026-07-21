# frozen_string_literal: true

# Posts a once-a-day paper-trading summary to Slack so the operator can watch the
# validation sample build (Stage 2) without SSHing in: trades taken, win rate,
# realized PnL, MAE (avg + worst), average holding time, open positions, equity.
class DailySummaryJob < ApplicationJob
  queue_as :default

  def perform(since: 24.hours.ago, notifier: SlackNotificationService)
    data = summary(since)
    notifier.alert("info", "📈 Daily Paper Summary (24h)", format_summary(data))
  end

  private

  def summary(since)
    closed = Position.closed.where(paper: true).where("close_time >= ?", since).to_a
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
      equity: PaperAccount.new.equity.round(2)
    }.merge(cost_metrics(closed, wins))
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
    CostModel.round_trip_cost(
      entry_price: notional_price,
      exit_price: notional_price,
      quantity: position.size.to_f,
      fee_rate: CostModel.taker_fee_rate,
      contracts: position.size.to_f
    )
  end

  def contract_size(product_id)
    Trading::ContractSizeResolver.for_product(product_id).to_f
  end

  def format_summary(d)
    [
      "Trades: #{d[:trades]} (#{d[:wins]} wins, #{d[:win_rate]}% win rate)",
      "Realized PnL: $#{d[:realized_pnl]}",
      "Avg MAE: #{money(d[:avg_mae])} | Worst MAE: #{money(d[:worst_mae])}",
      "Avg hold: #{d[:avg_hold_min] ? "#{d[:avg_hold_min]} min" : "n/a"}",
      cost_line(d),
      "Open now: #{d[:open]} | Paper equity: $#{d[:equity]}"
    ].compact.join("\n")
  end

  def cost_line(d)
    return nil if d[:cost_per_round_trip].nil?

    pct = d[:cost_pct_of_avg_win] ? " (#{d[:cost_pct_of_avg_win]}% of avg win)" : ""
    verdict = d[:cost_gate_passed] ? "PASS" : "FAIL"
    "Est. cost/round-trip: $#{d[:cost_per_round_trip]}#{pct} | Net of costs: $#{d[:net_of_costs]} → #{verdict}"
  end

  def money(value)
    value.nil? ? "n/a" : "$#{value}"
  end
end
