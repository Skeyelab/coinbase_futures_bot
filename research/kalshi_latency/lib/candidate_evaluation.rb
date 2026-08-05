# Turns a day of observations into the one thing StationEvidence can learn
# from: what each RIVAL station would have called, next to what settled.
#
# The models already answer "given this extreme, what is this contract?". The
# only new idea here is running that question once per candidate station rather
# than once for the incumbent, so that a day where the rivals disagree becomes
# evidence about which station the market actually settles on.
#
# Deliberately pure. Fetching observations and settlements is the caller's job,
# which keeps the part that decides things testable without a network.
module CandidateEvaluation
  module_function

  # final: the day is over, so :open is not "not yet" -- it is "never got
  # there", which settles NO. Mid-day it genuinely means no claim; after
  # settlement it is a claim, and the most common one.
  def day_records(date:, markets:, extremes:, settlements:, final: false)
    markets.filter_map do |market|
      settled = settlements[market.ticker]
      next if settled.nil? || settled.to_s.empty?

      # :open is not a call. Scoring it would fault a station for declining to
      # guess -- and an [open, refuted] pair reads as disagreement, which would
      # manufacture evidence out of one station's silence.
      calls = extremes.filter_map { |station, extreme|
        says = market.status_given(extreme)
        says = :refuted if says == :open && final
        next if says == :open

        {station: station, says: says.to_s}
      }

      {date: date, ticker: market.ticker, settled: settled, calls: calls}
    end
  end
end
