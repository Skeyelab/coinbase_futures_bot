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
          metrics: result.to_h.except(:trades)
        }
        cursor += eval_span
      end

      {windows: windows, aggregate: aggregate(windows)}
    end

    private

    def aggregate(windows)
      metrics = windows.map { |w| w[:metrics] }
      win_rates = metrics.filter_map { |m| m[:win_rate] }
      {
        window_count: windows.size,
        trade_count: metrics.sum { |m| m[:trade_count] },
        total_pnl: metrics.sum { |m| m[:total_pnl] },
        total_fees: metrics.sum { |m| m[:total_fees] },
        mean_win_rate: win_rates.empty? ? nil : win_rates.sum / win_rates.size,
        worst_window_drawdown: metrics.map { |m| m[:max_drawdown] }.max,
        profitable_windows: metrics.count { |m| m[:total_pnl] > 0 }
      }
    end
  end
end
