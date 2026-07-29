# frozen_string_literal: true

module Backtest
  # Issue #568 rank-3 / #569: judge Strategy::FundingSkewContrarian with BOTH
  # #541 gates over the walk-forward harness, in one call the operator can
  # run on the box.
  #
  #   - baseline walk-forward at 1h step (the signal is an hourly state; a
  #     finer step would re-ask the same premium 12x per hour)
  #   - Gates::PessimisticCost at 1.5x/2x off the walk-forward aggregate
  #     (fees + funding — and unlike the maker-band run, fees here are REAL
  #     taker fees on every leg, so the stress bites)
  #   - Gates::ParameterPlateau over a 5x5 grid on the strategy's OWN axes:
  #     WINDOW (regime memory) and ENTRY_Z (trigger extremity). The gate's
  #     historical cell keys are reused as labels: stop_scale carries the
  #     window scale, target_scale carries the entry_z scale.
  #
  # Default fill model (:touch) and venue taker fees apply — taker entries
  # are this candidate's cost reality, part of what the gates must kill it
  # on if the edge is thinner than the fee.
  class FundingSkewEvaluation
    WINDOW_SCALES = [0.5, 0.75, 1.0, 1.25, 1.5].freeze
    ENTRY_Z_SCALES = [0.8, 0.9, 1.0, 1.1, 1.2].freeze

    class << self
      def run(symbol:, from:, to:, train_span: 14.days, eval_span: 7.days,
        config: {}, window_scales: WINDOW_SCALES, entry_z_scales: ENTRY_Z_SCALES,
        **engine_options)
        baseline = Strategy::FundingSkewContrarian::DEFAULTS.merge(config)

        baseline_report = walk_forward(symbol, baseline, from, to, train_span, eval_span, engine_options)
        pessimistic = Gates::PessimisticCost.from_walk_forward(baseline_report)

        cells = window_scales.product(entry_z_scales).map do |w_scale, z_scale|
          report = if (w_scale - 1.0).abs < 1e-9 && (z_scale - 1.0).abs < 1e-9
            baseline_report # the baseline cell is the baseline run
          else
            walk_forward(symbol, scaled(baseline, w_scale, z_scale), from, to,
              train_span, eval_span, engine_options)
          end
          aggregate = report[:aggregate]
          {stop_scale: w_scale, target_scale: z_scale,
           net_pnl: aggregate[:total_pnl].to_f, trade_count: aggregate[:trade_count].to_i}
        end
        plateau = Gates::ParameterPlateau.evaluate(cells: cells)

        {
          config: baseline,
          walk_forward: baseline_report,
          plateau: plateau,
          pessimistic_cost: pessimistic,
          passed: plateau[:passed] && pessimistic[:passed]
        }
      end

      private

      def walk_forward(symbol, config, from, to, train_span, eval_span, engine_options)
        WalkForward.new(symbol: symbol, step: "1h",
          strategy: Strategy::FundingSkewContrarian.new(config),
          **engine_options)
          .run(from: from, to: to, train_span: train_span, eval_span: eval_span)
      end

      # The window scales in whole hours, floored at 2 so a scaled cell keeps
      # a defined sample stddev; entry_z scales the trigger alone (exit_z
      # stays put — the exit is part of the trade's definition, not its
      # tuning surface here).
      def scaled(config, w_scale, z_scale)
        config.merge(
          window: [(config[:window] * w_scale).round, 2].max,
          entry_z: config[:entry_z] * z_scale
        )
      end
    end
  end
end
