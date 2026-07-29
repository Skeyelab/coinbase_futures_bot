# frozen_string_literal: true

require "etc"

module Backtest
  module Gates
    # Gate 6 of the #376 go-live framework (issue #541): parameter PLATEAU,
    # not peak. A candidate tp/sl configuration must sit in a region of
    # parameter space where its neighbours are also net-positive. Gate 4
    # (walk-forward window consistency) covers stability across TIME; a config
    # can pass it and still be a knife-edge in PARAMETER space — the classic
    # signature of a curve fit. This gate closes that gap.
    #
    # Neighborhood, per the issue: 50/75/100/125/150% of the baseline stop
    # crossed with 80/90/100/110/120% of the baseline target — the full 5x5
    # grid, because a ridge along one axis can still be a cliff along the
    # other. Neighbours must merely stay net-positive, not match the baseline:
    # the claim is "not off a cliff", not "equally good".
    #
    # Two entry points so the gate can judge results it did not produce
    # (e.g. the #485 target-shape sweep):
    #   .run       — sweeps the grid through the existing walk-forward harness
    #   .evaluate  — judges any precomputed grid of {stop_scale:, target_scale:, net_pnl:}
    class ParameterPlateau
      STOP_SCALES = [0.5, 0.75, 1.0, 1.25, 1.5].freeze
      TARGET_SCALES = [0.8, 0.9, 1.0, 1.1, 1.2].freeze

      class << self
        # Judge a precomputed grid. Each cell: {stop_scale:, target_scale:,
        # net_pnl:, trade_count: (optional)}. A cell passes iff net-positive;
        # a zero-trade cell therefore fails — a neighbour that never traded is
        # silence, not evidence of a plateau. The baseline (1.0/1.0) cell is
        # required and must itself pass: this gate is additive with the cost
        # gate, never a substitute for it.
        def evaluate(cells:)
          judged = cells.map do |cell|
            cell.merge(passed: cell[:net_pnl].to_f > 0)
          end
          baseline = judged.find { |c| baseline?(c) }
          raise ArgumentError, "grid must include the baseline cell (stop_scale: 1.0, target_scale: 1.0)" unless baseline

          failing = judged.reject { |c| c[:passed] }
          {
            gate: "parameter_plateau",
            passed: failing.empty?,
            cell_count: judged.size,
            cells: judged,
            failing_cells: failing,
            baseline: baseline
          }
        end

        # Sweep the scale grid through the walk-forward harness — one
        # out-of-sample walk-forward run per cell, tp/sl scaled off the
        # effective profile baseline. No new data needed: only the strategy's
        # tp_target/sl_target overrides change per run.
        # Cells are independent — each builds its own strategy and WalkForward
        # over committed candles — so with processes > 1 they fan out across
        # forked workers (issue #568; the GVL rules out threads). Fork safety:
        # Rails 8.1 discards inherited connection pools in forked children
        # (ActiveSupport::ForkTracker hook in PoolConfig), so each worker
        # lazily opens its own DB connection and the parent's socket is never
        # shared; the Preloaded candle source and all engine state are
        # per-instance, built inside the worker. Parallel.map marshals plain
        # cell hashes back in input order, so the verdict is deterministic
        # regardless of which worker finishes first. processes: 1 is the
        # exact sequential path — no fork, no Parallel.
        def run(symbol:, from:, to:, train_span:, eval_span:,
          stop_scales: STOP_SCALES, target_scales: TARGET_SCALES,
          profile: TradingProfile.effective, processes: default_processes, **engine_options)
          baseline_tp = profile.tp_target.to_f
          baseline_sl = profile.sl_target.to_f

          grid = stop_scales.product(target_scales)
          evaluate_cell = lambda do |(stop_scale, target_scale)|
            # resolve_symbols: false — backtest mode, use the symbol as-is
            # (same as Engine's own default strategy construction).
            strategy = Trading::StrategyFactory.multi_timeframe(
              profile: profile, resolve_symbols: false,
              tp_target: baseline_tp * target_scale, sl_target: baseline_sl * stop_scale
            )
            aggregate = WalkForward.new(symbol: symbol, strategy: strategy, **engine_options)
              .run(from: from, to: to, train_span: train_span, eval_span: eval_span)
              .fetch(:aggregate)
            {
              stop_scale: stop_scale, target_scale: target_scale,
              net_pnl: aggregate[:total_pnl].to_f, trade_count: aggregate[:trade_count].to_i
            }
          end

          cells = if processes > 1
            Parallel.map(grid, in_processes: processes, &evaluate_cell)
          else
            grid.map(&evaluate_cell)
          end

          evaluate(cells: cells).merge(baseline_tp_target: baseline_tp, baseline_sl_target: baseline_sl)
        end

        # How many worker processes the grid sweep uses. PLATEAU_PROCESSES
        # overrides; default leaves two cores for the OS/bot and caps at 8
        # (25 cells — more workers than that is fork overhead, not speedup).
        # Always at least 1; 1 means the plain sequential path, no forking.
        def default_processes
          override = ENV["PLATEAU_PROCESSES"]
          return [override.to_i, 1].max if override

          (Etc.nprocessors - 2).clamp(1, 8)
        end

        private

        # Tolerant float match: scales arrive through arithmetic (sweep code
        # may compute them), so exact == on floats would be unreliable.
        def baseline?(cell)
          (cell[:stop_scale].to_f - 1.0).abs < 1e-9 && (cell[:target_scale].to_f - 1.0).abs < 1e-9
        end
      end
    end
  end
end
