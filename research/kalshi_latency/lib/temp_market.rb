# A Kalshi daily-high temperature market, and what the day's running maximum
# already tells us about it.
#
# The whole edge lives in one asymmetry. A running maximum only ever goes up,
# so an observation can:
#
#   - REFUTE a bucket or ceiling, the moment the day gets hotter than its top
#   - CONFIRM a floor, the moment the day reaches it
#
# It can never confirm a bucket early (the day might keep warming past it) and
# never refute a floor early (the day might still reach it). So a new daily
# high is a one-way ratchet that zeroes out everything beneath it. No
# forecasting, no judgement: if the max is already 85, every bucket below 85 is
# worth exactly zero, and anything still bidding for them is paying for a fact
# that is already public.
class TempMarket
  KINDS = %i[between greater less].freeze

  attr_reader :ticker, :kind, :floor, :cap

  def initialize(ticker:, kind:, floor:, cap:)
    raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind)

    @ticker = ticker
    @kind = kind
    @floor = floor
    @cap = cap
  end

  def status_given(running_high)
    return :open if running_high.nil?

    # Kalshi settles on the NWS daily climate report, which publishes whole
    # degrees. An 89.4F reading is an 89 degree day. Comparing the raw
    # observation would invent edges in every half-degree band.
    degrees = settling_degrees(running_high)

    case kind
    when :between, :less
      # Overshooting the top of the range settles it against us, permanently.
      (degrees > cap) ? :refuted : :open
    when :greater
      (degrees >= floor) ? :confirmed : :open
    end
  end

  def settling_degrees(running_high)
    running_high.round
  end

  # What the contract is already worth, or nil while the day can still go
  # either way.
  def settled_value_cents(running_high)
    case status_given(running_high)
    when :refuted then 0
    when :confirmed then 100
    end
  end

  # Builds from the Kalshi markets payload. floor_strike/cap_strike arrive as
  # whole degrees; strike_type names the shape.
  def self.from_api(market)
    kind = market["strike_type"].to_s.to_sym
    return nil unless KINDS.include?(kind)

    new(
      ticker: market["ticker"],
      kind: kind,
      floor: market["floor_strike"]&.to_f,
      cap: market["cap_strike"]&.to_f
    )
  end
end
