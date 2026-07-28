# frozen_string_literal: true

# Posts a once-a-day paper-trading summary to Slack so the operator can watch the
# validation sample build (Stage 2) without SSHing in: trades taken, win rate,
# realized PnL, MAE (avg + worst), average holding time, open positions, equity.
class DailySummaryJob < ApplicationJob
  queue_as :default

  def perform(since: 24.hours.ago, notifier: SlackNotificationService)
    data = summary(since)
    notifier.alert("info", "📈 Daily Paper Summary (24h)", format_summary(data))

    # PostHog: Track daily summary dispatch
    PostHog.capture(
      distinct_id: "system",
      event: "daily_summary_dispatched",
      properties: {
        trades: data[:trades],
        win_rate: data[:win_rate],
        realized_pnl: data[:realized_pnl],
        net_of_costs: data[:net_of_costs],
        cost_gate_passed: data[:cost_gate_passed],
        open_positions: data[:open],
        equity: data[:equity]
      }
    )
  end

  private

  # Delegates to Trading::PaperPnlSummary — the single source for paper PnL over
  # a window. This job used to own the computation, and a second, wrong copy grew
  # in the day-trading workflow's Slack card (see that class for what it reported).
  def summary(since)
    Trading::PaperPnlSummary.call(since: since)
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
