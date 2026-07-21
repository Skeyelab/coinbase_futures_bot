# frozen_string_literal: true

module Backtest
  # Walk-forward evaluation (issue #298): rolls a train/eval window across
  # history and reports per-window OUT-OF-SAMPLE metrics — each window's
  # metrics come only from its eval span, which the strategy has not been
  # tuned on. (Parameter tuning on the train span is the calibration
  # ticket's job; here the train span defines the honest window layout.)
  class WalkForward
    def initialize(**engine_options)
      @engine_options = engine_options
    end

    def run(from:, to:, train_span:, eval_span:)
      raise ArgumentError, "span too short for a single train+eval window" if from + train_span + eval_span > to

      windows = []
      cursor = from
      while cursor + train_span < to
        train_to = cursor + train_span
        eval_to = [train_to + eval_span, to].min
        result = Engine.new(**@engine_options).run(from: train_to, to: eval_to)
        windows << {
          train_from: cursor.iso8601,
          train_to: train_to.iso8601,
          eval_from: train_to.iso8601,
          eval_to: eval_to.iso8601,
          metrics: result.to_h.except(:trades),
          # Issue #378: a zero-trade window with low 1m coverage is
          # data-starved, not signal-quiet — make that visible.
          data_coverage: data_coverage(train_to, eval_to)
        }
        cursor += eval_span
      end

      {windows: windows, aggregate: aggregate(windows)}
    end

    private

    # Fraction of the eval window covered by stored candles per timeframe
    # (candles present / candles expected for a fully-covered window).
    def data_coverage(from, to)
      symbol = @engine_options.fetch(:symbol)
      span_minutes = ((to - from) / 60).to_f
      {
        one_minute: coverage_fraction(symbol, "1m", from, to, span_minutes),
        five_minute: coverage_fraction(symbol, "5m", from, to, span_minutes / 5)
      }
    end

    def coverage_fraction(symbol, timeframe, from, to, expected)
      return 0.0 unless expected.positive?

      count = Candle.where(symbol: symbol, timeframe: timeframe, timestamp: from..to).count
      [(count / expected).round(4), 1.0].min
    end

    def aggregate(windows)
      metrics = windows.map { |w| w[:metrics] }
      win_rates = metrics.filter_map { |m| m[:win_rate] }
      trade_count = metrics.sum { |m| m[:trade_count] }
      total_pnl = metrics.sum { |m| m[:total_pnl] }
      expectancy = trade_count.positive? ? total_pnl / trade_count : nil
      {
        window_count: windows.size,
        trade_count: trade_count,
        total_pnl: total_pnl,
        total_fees: metrics.sum { |m| m[:total_fees] },
        expectancy: expectancy,
        cost_gate_passed: expectancy.nil? ? nil : expectancy > 0,
        mean_win_rate: win_rates.empty? ? nil : win_rates.sum / win_rates.size,
        worst_window_drawdown: metrics.map { |m| m[:max_drawdown] }.max,
        profitable_windows: metrics.count { |m| m[:total_pnl] > 0 }
      }
    end
  end
end
