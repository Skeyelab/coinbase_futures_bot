require "json"
require_relative "t_cdf"

# Turns an NBM point forecast + ensemble spread into a probability for one
# Kalshi temperature bucket, using the per-(station, lead-bin) error models
# fitted in research/ensemble_calibration (params.json is the artifact; the
# fitting stays in Python, this only evaluates).
#
# P(H = t) = F((t+0.5 - txn - mu)/sigma) - F((t-0.5 - txn - mu)/sigma)
# with sigma = a + b * xnd, summed over the bucket using the same bound rules
# the ratchet models use: between is both-inclusive, greater is
# floor-exclusive, less is cap-exclusive.
module BucketPricer
  PARAMS_PATH = File.expand_path(
    "../research/ensemble_calibration/params.json", __dir__
  )
  LEAD_BINS = [[13, 24, "13-24h"], [24, 42, "24-42h"], [42, 66, "42-66h"]].freeze

  def self.params
    @params ||= JSON.parse(File.read(PARAMS_PATH))
  end

  # nil when the fit does not cover this station or lead — an uncovered cell
  # is "no opinion", never a guessed probability.
  def self.probability(market:, txn:, xnd:, station:, lead_hours:)
    cell = cell_for(station, lead_hours)
    return nil unless cell

    mu = txn + cell["mu"]
    sigma = cell["a"] + cell["b"] * xnd
    df = cell["nu"]

    case market.kind
    when :between then cdf_below(market.cap, mu, sigma, df) - cdf_below(market.floor - 1, mu, sigma, df)
    when :greater then 1.0 - cdf_below(market.floor, mu, sigma, df)
    when :less then cdf_below(market.cap - 1, mu, sigma, df)
    end
  end

  # P(H <= t) for integer t: the half-degree boundary is where a settled
  # whole-degree high rounds away.
  def self.cdf_below(t, mu, sigma, df)
    TCdf.cdf((t + 0.5 - mu) / sigma, df: df)
  end

  def self.cell_for(station, lead_hours)
    bin = LEAD_BINS.find { |lo, hi, _| lead_hours > lo && lead_hours <= hi }
    return nil unless bin

    params["cells"]["#{station}|#{bin[2]}"]
  end
end
