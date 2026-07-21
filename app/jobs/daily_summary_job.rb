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
    }
  end

  def format_summary(d)
    [
      "Trades: #{d[:trades]} (#{d[:wins]} wins, #{d[:win_rate]}% win rate)",
      "Realized PnL: $#{d[:realized_pnl]}",
      "Avg MAE: #{money(d[:avg_mae])} | Worst MAE: #{money(d[:worst_mae])}",
      "Avg hold: #{d[:avg_hold_min] ? "#{d[:avg_hold_min]} min" : "n/a"}",
      "Open now: #{d[:open]} | Paper equity: $#{d[:equity]}"
    ].join("\n")
  end

  def money(value)
    value.nil? ? "n/a" : "$#{value}"
  end
end
