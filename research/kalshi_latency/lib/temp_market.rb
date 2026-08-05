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

    # Kalshi's strike bounds are NOT uniformly inclusive, and the difference is
    # a whole degree of settlement:
    #
    #   between  B89.5  floor=89 cap=90  "89 to 90"      both INCLUSIVE
    #   greater  T90    floor=90         "91 or above"   floor EXCLUSIVE
    #   less     T83    cap=83           "82 or below"   cap   EXCLUSIVE
    #
    # Reading them all as inclusive confirmed a Philadelphia contract at 90
    # that actually needs 91, and the scanner reported free money that was an
    # off-by-one.
    case kind
    when :between
      (degrees > cap) ? :refuted : :open
    when :less
      (degrees >= cap) ? :refuted : :open
    when :greater
      (degrees > floor) ? :confirmed : :open
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
  # What an :open contract settles as once the day is OVER.
  #
  # A daily maximum can only rise, so :open means it never got there. That
  # resolves a "reach this level" contract NO and a "stay below this level"
  # contract YES. Answering :refuted for both -- the obvious blanket rule --
  # scores every less market backwards, which is half the board.
  def settles_open_as
    (kind == :less) ? :confirmed : :refuted
  end

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
