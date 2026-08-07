# Reasons to distrust a settled-fact claim.
#
# All three were learned the same way: the scanner reported an opportunity, the
# market disagreed, and the market was right. Empty means nothing looks wrong,
# not that the claim is proven.
module Credibility
  # A contested market. Measured 2026-08-04: of 16 definite calls, 15 matched
  # the book at 0% and the one that did not (LAX at 76-93%) was my error.
  MAX_MARKET_PCT = 20

  # A peak standing on a single observation. Corroboration predicted market
  # agreement and MARGIN did not: KMIA 37 observations and KAUS 4 both agreed,
  # KLAX 1 observation disagreed -- while having the widest margin of the three.
  MIN_SUPPORT = 2

  # PERSISTENCE, and it reads the opposite way to a latency play.
  #
  # A settled fact is public, mechanical and obvious. A real one gets taken
  # quickly -- the only genuine-looking opportunity observed (Miami, 15:54Z)
  # was gone inside 70 seconds. LAX sat for 2,205 seconds at 93% market
  # confidence, which is not an opportunity nobody noticed; it is an error only
  # we are making.
  #
  # For a NEWS-latency trade long dwell is the edge. For a settled fact it is
  # the tell. Do not carry the intuition across.
  #
  # CONDITIONED ON MARKET DISAGREEMENT since 2026-08-07. Measured over 25
  # scored episodes (Aug 4-6): market agreement separates perfectly (11/11
  # correct when the book agreed, 4/14 when it disputed), and within agreeing
  # episodes persistence adds nothing -- 10/10 settled our way, several after
  # 45-75 minutes. The premise "a real fact gets taken fast" assumed a
  # counterparty; the measured rate of dead buckets with ANY bid is 5.9%, so
  # a long life measures an empty book rather than our error. Persistence
  # keeps its say exactly where it earned it: when the market disputes us
  # (KXHIGHLAX-26AUG04-B77.5 sat 19,041s at 99% and settled against us).
  MAX_PERSISTENCE_SECONDS = 300

  def self.doubts(episode, max_persistence: MAX_PERSISTENCE_SECONDS)
    reasons = []

    # An inferred settlement station is a guess, however obvious. Chicago
    # settles on Midway, not O'Hare, and nothing in the rules text says so for
    # the cities added 2026-08-04.
    reasons << "station unverified" if episode[:verified] == false

    pct = episode[:market_pct].to_i
    reasons << "market disagrees #{pct}%" if pct >= MAX_MARKET_PCT

    support = episode[:support]
    reasons << "lone spike (#{support} obs)" if !support.nil? && support.to_i < MIN_SUPPORT

    # Absent a recorded market_pct, agreement is UNKNOWN, not agreement: nil
    # reads as 0 through to_i, which would silently excuse every long episode.
    agreed = !episode[:market_pct].nil? && pct < MAX_MARKET_PCT
    seconds = episode[:seconds].to_i
    reasons << "persisted #{seconds}s" if seconds >= max_persistence && !agreed

    reasons
  end

  def self.credible?(episode, **opts)
    doubts(episode, **opts).empty?
  end
end
