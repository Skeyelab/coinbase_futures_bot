# frozen_string_literal: true

module Backtest
  module Gates
    # Gate 7 of the #376 go-live framework (issue #541): survive PESSIMISTIC
    # costs. Gate 1 asks whether our cost numbers reconcile with reality; this
    # gate asks whether the edge survives reality being WORSE than measured —
    # net expectancy must stay positive with modeled costs at 1.5x and 2x, and
    # the gate reports the break-even cost multiple because the margin matters
    # more than the pass/fail. Motivated by #531 (a fee-modeling bug read as a
    # venue finding) and #486 (the ~3 bps perp taker rate is still unvalidated
    # by any real fill).
    #
    # The stress is ANALYTIC — same trades, scaled costs — rather than a
    # re-run of the engine at stressed rates. A re-run would let the strategy
    # adapt (its break-even gate widens targets as fees rise), which answers a
    # different, softer question; holding the trade set fixed is the
    # conservative reading of "costs turn out worse than modeled".
    #
    # Stressable costs are the explicitly modeled ones: fees + funding as
    # recorded per trade, plus slippage reconstructed from the modeled rate
    # when supplied (slippage lives inside fill prices, not on the trade
    # record, so it can only be estimated: rate x entry/exit notional).
    class PessimisticCost
      DEFAULT_MULTIPLES = [1.5, 2.0].freeze

      class << self
        # Core arithmetic on totals. Stressed net at multiple m:
        #   total_pnl - (m - 1) x stressable_costs
        # (total_pnl is already net of costs at 1x). Break-even multiple is
        # where that hits zero: 1 + total_pnl / stressable_costs.
        def evaluate(total_pnl:, stressable_costs:, trade_count:, multiples: DEFAULT_MULTIPLES)
          total_pnl = total_pnl.to_f
          stressable_costs = stressable_costs.to_f

          stressed = multiples.map do |multiple|
            net = total_pnl - (multiple - 1.0) * stressable_costs
            {
              multiple: multiple,
              net_pnl: net,
              expectancy: trade_count.positive? ? net / trade_count : nil,
              passed: trade_count.positive? && net > 0
            }
          end

          {
            gate: "pessimistic_cost",
            passed: stressed.all? { |m| m[:passed] },
            multiples: stressed,
            break_even_cost_multiple: break_even_multiple(total_pnl, stressable_costs, trade_count),
            seed: {
              net_pnl: total_pnl,
              expectancy: trade_count.positive? ? total_pnl / trade_count : nil,
              stressable_costs: stressable_costs,
              trade_count: trade_count
            }
          }
        end

        # Judge a Backtest::Result. Pass slippage_rate: (the engine's modeled
        # per-side rate) to include reconstructed slippage in the stress.
        def from_result(result, multiples: DEFAULT_MULTIPLES, slippage_rate: nil)
          costs = result.total_fees + result.total_funding +
            estimated_slippage(result.trades, slippage_rate)
          evaluate(total_pnl: result.total_pnl, stressable_costs: costs,
            trade_count: result.trade_count, multiples: multiples)
        end

        # Judge a walk-forward report ({windows:, aggregate:}) by its
        # aggregate totals — this is what lets the gate sit over the #485
        # sweep output instead of requiring a live engine run. Slippage is not
        # recoverable from aggregates (no per-trade notionals), so the stress
        # covers fees + funding there.
        def from_walk_forward(report, multiples: DEFAULT_MULTIPLES)
          aggregate = report.fetch(:aggregate)
          costs = aggregate[:total_fees].to_f + aggregate[:total_funding].to_f
          evaluate(total_pnl: aggregate[:total_pnl].to_f, stressable_costs: costs,
            trade_count: aggregate[:trade_count].to_i, multiples: multiples)
        end

        private

        # The multiple at which the edge dies. Below 1.0 means the strategy
        # is underwater at seed costs already (fails, and would fail gate 1's
        # premise too — these gates are additive). Infinity: profitable with
        # zero modeled costs, nothing to stress. Nil: no trades, no evidence.
        def break_even_multiple(total_pnl, stressable_costs, trade_count)
          return nil unless trade_count.positive?
          return Float::INFINITY if stressable_costs.zero? && total_pnl > 0
          return nil if stressable_costs.zero?

          1.0 + total_pnl / stressable_costs
        end

        # Slippage is applied adversely to both fills by the simulator, so the
        # per-trade dollar cost is approximately rate x (entry + exit) notional.
        def estimated_slippage(trades, slippage_rate)
          return 0.0 unless slippage_rate.to_f.positive?

          trades.sum do |t|
            qty = t[:quantity].to_f
            slippage_rate.to_f * (t[:entry_price].to_f * qty + t[:exit_price].to_f * qty)
          end
        end
      end
    end
  end
end
