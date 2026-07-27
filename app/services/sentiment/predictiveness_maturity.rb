# frozen_string_literal: true

module Sentiment
  # Labels how far to trust a predictiveness reading (issue #436). The operator
  # always sees the number; this tag says how seasoned the data behind it is, so
  # an early, noisy reading isn't over-read (#435).
  #
  # Originally this thresholded on raw row counts, and both gates were reachable
  # within days — so the label saturated at `high` almost immediately (#468). On
  # 2026-07-27, six days after collection began, every symbol read `high`,
  # including oil at a 0.25 hit rate. Read at face value that looks like a strong
  # inverse signal worth trading against; it is what six days of overlapping
  # windows produces by chance.
  #
  # Two things make raw `n` the wrong unit:
  #
  #   * Observations OVERLAP. Aggregates are spaced far tighter than the horizon
  #     they are scored against, so consecutive samples share most of their
  #     forward return. 134 rows at a 24h horizon over six days is nowhere near
  #     134 independent facts. Callers pass `effective_n` — observations spaced
  #     at least one horizon apart — not the row count.
  #   * CALENDAR SPAN bounds how many market regimes were sampled at all. No
  #     number of observations inside one quiet week makes that week
  #     representative, which is why span gates `high` independently.
  #
  # Because effective_n falls as the horizon grows, a 24h reading needs far more
  # span than a 1h one to earn the same label — which is the correct behavior.
  module PredictivenessMaturity
    MODERATE_EFFECTIVE_N = ENV.fetch("PREDICTIVENESS_MODERATE_EFFECTIVE_N", "10").to_i
    HIGH_EFFECTIVE_N = ENV.fetch("PREDICTIVENESS_HIGH_EFFECTIVE_N", "30").to_i
    MIN_SIGNALS = ENV.fetch("PREDICTIVENESS_MIN_SIGNALS", "20").to_i
    # A month is the floor for calling any reading seasoned, regardless of how
    # much data sits inside it.
    HIGH_SPAN_DAYS = ENV.fetch("PREDICTIVENESS_HIGH_SPAN_DAYS", "30").to_i

    def self.label(effective_n:, signal_count:, span_days:)
      independent = effective_n.to_i
      signals = signal_count.to_i
      span = span_days.to_f

      if independent >= HIGH_EFFECTIVE_N && signals >= MIN_SIGNALS && span >= HIGH_SPAN_DAYS
        return "high"
      end
      return "moderate" if independent >= MODERATE_EFFECTIVE_N

      "low"
    end
  end
end
