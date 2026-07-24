# frozen_string_literal: true

module Sentiment
  # Labels how far to trust a predictiveness reading (issue #436). The operator
  # always sees the number; this tag says how seasoned the data behind it is, so
  # an early, noisy reading isn't over-read (#435). Thresholds are config knobs.
  module PredictivenessMaturity
    MODERATE_N = ENV.fetch("PREDICTIVENESS_MODERATE_N", "30").to_i
    HIGH_N = ENV.fetch("PREDICTIVENESS_HIGH_N", "100").to_i
    MIN_SIGNALS = ENV.fetch("PREDICTIVENESS_MIN_SIGNALS", "20").to_i

    def self.label(n:, signal_count:)
      total = n.to_i
      signals = signal_count.to_i
      return "high" if total >= HIGH_N && signals >= MIN_SIGNALS
      return "moderate" if total >= MODERATE_N

      "low"
    end
  end
end
