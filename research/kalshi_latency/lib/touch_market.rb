# A one-touch market: pays YES if the underlying ever reaches a level before
# expiry.
#
# Same ratchet as a daily high temperature, one level up in abstraction. The
# observable is a running EXTREME -- a maximum that only rises, or a minimum
# that only falls -- so once it passes the threshold the outcome is fixed and
# cannot come back. Price returning above $60,000 does not un-touch it.
#
# The asymmetry is the point, and it is the opposite of a bucket's:
#
#   TempMarket bucket   can be REFUTED early, never confirmed early
#   TouchMarket         can be CONFIRMED early, never refuted early
#
# So the tradeable side here is BUYING a contract already touched but still
# priced under 100 -- never selling one that has not touched, because the
# remaining time can always deliver the touch.
class TouchMarket
  DIRECTIONS = %i[above below].freeze

  attr_reader :ticker, :direction, :threshold

  def initialize(ticker:, direction:, threshold:)
    raise ArgumentError, "unknown direction #{direction}" unless DIRECTIONS.include?(direction)

    @ticker = ticker
    @direction = direction
    @threshold = threshold
  end

  # `observed` is the running extreme in the direction that matters: the
  # maximum for an :above market, the minimum for a :below one.
  def status_given(observed)
    return :open if observed.nil? || threshold.nil?

    touched?(observed.to_f) ? :confirmed : :open
  end

  private

  # Strict comparison. Kalshi writes these strikes to land clear of the level
  # ("Above $99,999.99" rather than "Above $100,000"), so the boundary is
  # already expressed in the number and does not need widening here.
  def touched?(observed)
    (direction == :above) ? observed > threshold : observed < threshold
  end
end
