# frozen_string_literal: true

module Backtest
  # Metrics for one backtest run (issue #298). JSON-serializable via #to_h.
  # Trades are hashes: {side:, entry_price:, exit_price:, quantity:, pnl:,
  # fees:, entered_at:, exited_at:}.
  class Result
    attr_reader :trades, :equity_curve, :starting_equity, :from, :to

    def initialize(trades:, equity_curve:, starting_equity:, from:, to:)
      @trades = trades
      @equity_curve = equity_curve
      @starting_equity = starting_equity.to_f
      @from = from
      @to = to
    end

    def trade_count
      trades.size
    end

    def total_pnl
      trades.sum { |t| t[:pnl].to_f }
    end

    def total_fees
      trades.sum { |t| t[:fees].to_f }
    end

    def win_rate
      return nil if trades.empty?

      trades.count { |t| t[:pnl].to_f > 0 } / trades.size.to_f
    end

    def wins
      trades.select { |t| t[:pnl].to_f > 0 }
    end

    def losses
      trades.select { |t| t[:pnl].to_f <= 0 }
    end

    def avg_win
      return nil if wins.empty?

      wins.sum { |t| t[:pnl].to_f } / wins.size
    end

    def avg_loss
      return nil if losses.empty?

      losses.sum { |t| t[:pnl].to_f } / losses.size
    end

    # Average fees paid per completed round trip.
    def cost_per_round_trip
      return nil if trades.empty?

      total_fees / trades.size
    end

    # Issue #353: cost per round trip as a percentage of the average win —
    # the "hidden cost" gauge for Stage-2 validation.
    def cost_pct_of_avg_win
      return nil if cost_per_round_trip.nil? || avg_win.nil? || avg_win <= 0

      cost_per_round_trip / avg_win * 100.0
    end

    # Largest peak-to-trough decline on the equity curve, as a fraction of
    # the running peak.
    def max_drawdown
      peak = -Float::INFINITY
      max_dd = 0.0
      equity_curve.each do |eq|
        eq = eq.to_f
        peak = eq if eq > peak
        dd = (peak - eq) / peak if peak.positive?
        max_dd = dd if dd && dd > max_dd
      end
      max_dd
    end

    # Mean per-trade PnL over its sample standard deviation, scaled by
    # sqrt(trade count). Not annualized — comparable across windows of the
    # same granularity, which is what walk-forward needs.
    def sharpe_like
      return nil if trades.size < 2

      pnls = trades.map { |t| t[:pnl].to_f }
      mean = pnls.sum / pnls.size
      variance = pnls.sum { |p| (p - mean)**2 } / (pnls.size - 1)
      std = Math.sqrt(variance)
      return nil if std.zero?

      mean / std * Math.sqrt(pnls.size)
    end

    def final_equity
      (equity_curve.last || starting_equity).to_f
    end

    def to_h
      {
        from: from&.utc&.iso8601,
        to: to&.utc&.iso8601,
        starting_equity: starting_equity,
        final_equity: final_equity,
        trade_count: trade_count,
        total_pnl: total_pnl,
        total_fees: total_fees,
        win_rate: win_rate,
        avg_win: avg_win,
        avg_loss: avg_loss,
        cost_per_round_trip: cost_per_round_trip,
        cost_pct_of_avg_win: cost_pct_of_avg_win,
        max_drawdown: max_drawdown,
        sharpe_like: sharpe_like,
        trades: trades.map { |t| t.merge(entered_at: t[:entered_at]&.utc&.iso8601, exited_at: t[:exited_at]&.utc&.iso8601) }
      }
    end
  end
end
