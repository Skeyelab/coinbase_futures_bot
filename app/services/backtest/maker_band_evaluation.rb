# frozen_string_literal: true

module Backtest
  # Issue #568: judge Strategy::MakerBandReversion with BOTH #541 gates over
  # the walk-forward harness, in one call the operator can run on the box.
  #
  #   - baseline walk-forward (14d/7d convention via the caller's spans)
  #   - Gates::PessimisticCost at 1.5x/2x off the walk-forward aggregate
  #     (fees + funding; slippage is not recoverable from aggregates — with
  #     maker fills unslipped, the only slippage in the model is on stop
  #     exits, which understates the stress slightly, never overstates it)
  #   - Gates::ParameterPlateau over a 5x5 grid around the strategy's OWN
  #     axes: N (anchor_period + vol_period together) and k (band_k). The
  #     gate's historical cell keys are reused as labels: stop_scale carries
  #     the N scale, target_scale carries the k scale.
  #
  # Every cell re-runs the walk-forward with fill_model: :through_price, so
  # the plateau is judged under the same pessimistic fill rule as the
  # baseline — a plateau that only exists at-touch is a fill-model artifact.
  class MakerBandEvaluation
    N_SCALES = [0.5, 0.75, 1.0, 1.25, 1.5].freeze
    K_SCALES = [0.8, 0.9, 1.0, 1.1, 1.2].freeze

    class << self
      def run(symbol:, from:, to:, train_span: 14.days, eval_span: 7.days,
        config: {}, n_scales: N_SCALES, k_scales: K_SCALES, **engine_options)
        baseline = Strategy::MakerBandReversion::DEFAULTS.merge(config)

        baseline_report = walk_forward(symbol, baseline, from, to, train_span, eval_span, engine_options)
        pessimistic = Gates::PessimisticCost.from_walk_forward(baseline_report)

        cells = n_scales.product(k_scales).map do |n_scale, k_scale|
          report = if (n_scale - 1.0).abs < 1e-9 && (k_scale - 1.0).abs < 1e-9
            baseline_report # the baseline cell is the baseline run
          else
            walk_forward(symbol, scaled(baseline, n_scale, k_scale), from, to,
              train_span, eval_span, engine_options)
          end
          aggregate = report[:aggregate]
          {stop_scale: n_scale, target_scale: k_scale,
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
        WalkForward.new(symbol: symbol, step: "5m",
          strategy: Strategy::MakerBandReversion.new(config),
          fill_model: :through_price, maker_fee_rate: 0.0,
          **engine_options)
          .run(from: from, to: to, train_span: train_span, eval_span: eval_span)
      end

      # Periods scale together (the band's memory), floored at 2 so a scaled
      # cell is always computable; k scales the band width alone.
      def scaled(config, n_scale, k_scale)
        config.merge(
          anchor_period: [(config[:anchor_period] * n_scale).round, 2].max,
          vol_period: [(config[:vol_period] * n_scale).round, 2].max,
          band_k: config[:band_k] * k_scale
        )
      end
    end
  end
end
