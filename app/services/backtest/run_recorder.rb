# frozen_string_literal: true

module Backtest
  # The one place a backtest becomes a BacktestRun row (issue #406).
  #
  # Metrics are taken from Result#to_h rather than re-derived, so the stored
  # numbers are by construction the same ones the CLI prints — there is no
  # second implementation to drift. The heavy payloads (trades, equity curve)
  # are split into their own columns so index views can skip them.
  class RunRecorder
    class << self
      def record_single(engine:, result:, started_at: nil, finished_at: nil)
        payload = result.to_h
        trades = payload.delete(:trades)

        BacktestRun.create!(
          **engine_inputs(engine),
          kind: "single",
          from_time: result.from,
          to_time: result.to,
          status: "succeeded",
          metrics: payload,
          trades: trades,
          equity_curve: result.equity_curve,
          started_at: started_at,
          finished_at: finished_at
        )
      end

      # Walk-forward reports {windows:, aggregate:} rather than a Result: the
      # per-window metrics are the point, and the aggregate is the summary. The
      # windows blob carries data_coverage, which is what tells a reader whether
      # a window was actually evaluated on real candles.
      def record_walk_forward(engine:, report:, from:, to:, train_days:, eval_days:,
        started_at: nil, finished_at: nil)
        BacktestRun.create!(
          **engine_inputs(engine),
          kind: "walk_forward",
          from_time: from,
          to_time: to,
          train_days: train_days,
          eval_days: eval_days,
          status: "succeeded",
          metrics: report[:aggregate],
          windows: report[:windows],
          started_at: started_at,
          finished_at: finished_at
        )
      end

      # Records a run that raised. Without this a failure leaves no trace at
      # all, which is the same write-only hole this issue exists to close.
      def record_failure(engine:, from:, to:, kind:, error:, started_at: nil, finished_at: nil)
        BacktestRun.create!(
          **engine_inputs(engine),
          kind: kind,
          from_time: from,
          to_time: to,
          status: "failed",
          error_message: "#{error.class}: #{error.message}",
          started_at: started_at,
          finished_at: finished_at
        )
      end

      private

      # The resolved values, not the caller's arguments — see Engine's readers.
      def engine_inputs(engine)
        {
          symbol: engine.symbol,
          step: engine.step,
          starting_equity: engine.starting_equity,
          fee_rate: engine.fee_rate,
          # The per-contract floor too (issue #471): fee_rate alone is a lossy
          # projection of the venue's fee shape, so a run stored without this
          # cannot be re-costed faithfully later.
          per_contract_fee: engine.per_contract_fee,
          slippage: engine.slippage,
          contract_size_usd: engine.contract_size_usd
        }
      end
    end
  end
end
