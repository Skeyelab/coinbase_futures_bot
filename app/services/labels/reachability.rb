# frozen_string_literal: true

module Labels
  # Reads persisted path-dependent labels and answers the standalone #302
  # question: how often are our tp/sl targets even reachable? Per direction:
  # the share of bars whose race resolved as a win (winnable_pct), the win
  # rate among resolved races, and the honest effective sample size —
  # overlapping horizons make neighboring labels correlated, so effective
  # independent observations ~= span_bars / horizon, not raw n (the PRD's
  # honest-n caveat). Raw n is reported alongside, never instead.
  module Reachability
    module_function

    # Returns {long: {...}, short: {...}} for one symbol + label shape.
    # Optional from/to restrict to a bar_timestamp window.
    def report(symbol:, tp_frac:, sl_frac:, horizon:, timeframe: PathDependent::DEFAULT_TIMEFRAME, from: nil, to: nil)
      scope = PathDependentLabel.where(symbol: symbol, timeframe: timeframe)
        .for_shape(tp_frac: tp_frac, sl_frac: sl_frac, horizon: horizon)
      scope = scope.where(bar_timestamp: from..) if from
      scope = scope.where(bar_timestamp: ..to) if to

      counts = scope.group(:direction, :label).count

      PathDependentLabel::DIRECTIONS.to_h do |direction|
        wins = counts.fetch([direction, "win"], 0)
        losses = counts.fetch([direction, "loss"], 0)
        unresolved = counts.fetch([direction, "unresolved"], 0)
        n = wins + losses + unresolved
        resolved = wins + losses

        [direction.to_sym, {
          n: n,
          wins: wins,
          losses: losses,
          unresolved: unresolved,
          winnable_pct: percent(wins, n),
          win_rate_resolved_pct: percent(wins, resolved),
          # One label window spans `horizon` bars, so consecutive bars share
          # almost all of their future path: n bars of span support only
          # ~n / horizon independent observations.
          effective_n: (horizon.to_i.positive? ? n / horizon.to_i : 0)
        }]
      end
    end

    def percent(numerator, denominator)
      return 0.0 if denominator.zero?

      numerator * 100.0 / denominator
    end
  end
end
