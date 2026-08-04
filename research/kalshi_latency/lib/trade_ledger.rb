# Splits fills into two tracks that must never be added together.
#
#   :settled_fact  the system flagged this contract BEFORE the fill. These are
#                  the only trades that count as funding-gate evidence.
#   :directional   everything else. A view on where something is going, which
#                  may well be right, but says nothing about whether the
#                  settled-fact edge exists.
#
# THE CLASSIFICATION IS BY PRIOR CALL, NOT BY MARKET. The same ticker can be
# either: buying a temperature bucket the day has already refuted is arithmetic;
# buying it at dawn before any observation is a forecast. Only the recorded
# prior call distinguishes them.
#
# Deciding afterwards which trades "were really the strategy" is how a
# discretionary run gets laundered into a backtest. If the system did not call
# it in advance and leave a record, it is directional -- however obvious it
# looked at the time.
module TradeLedger
  def self.classify(fills, called_tickers:)
    called = called_tickers.to_a.to_set

    Array(fills).map do |f|
      ticker = f["ticker"].to_s
      {
        ticker: ticker,
        at: f["created_time"],
        action: f["action"],
        side: f["side"],
        # Kalshi fills use *_fp / *_dollars, not the bare names the docs suggest.
        count: f["count_fp"].to_f.round,
        price_cents: ((f["side"] == "no" ? f["no_price_dollars"] : f["yes_price_dollars"]).to_f * 100).round,
        fee_cents: (f["fee_cost"].to_f * 100).round(2),
        track: called.include?(ticker) ? :settled_fact : :directional
      }
    end
  end

  # Gate arithmetic only ever sees the settled-fact track.
  def self.gate_evidence(classified)
    classified.select { |t| t[:track] == :settled_fact }
  end

  def self.directional(classified)
    classified.select { |t| t[:track] == :directional }
  end
end
