# A Kalshi daily-LOW temperature market.
#
# Mirror of TempMarket. The observable is a running MINIMUM, which only ever
# falls, so which outcomes can be settled early is exactly reversed:
#
#   TempMarket (max rises)          LowTempMarket (min falls)
#   between  refuted if max > cap   between  refuted   if min < floor
#   greater  CONFIRMED if max > fl  greater  REFUTED   if min <= floor
#   less     refuted if max >= cap  less     CONFIRMED if min < cap
#
# Note the greater/less rows swap which side is settleable. On a high market a
# floor contract is the one that can be confirmed early; on a low market it is
# the one that can be REFUTED early. Reusing TempMarket here would report a
# live contract as settled and propose trading the wrong side of it.
#
# Verified against live KXLOWTPHIL-26AUG05 markets and their rules text.
# Settlement is the whole-degree NWS Climatological Report, same as highs.
class LowTempMarket
  KINDS = %i[between greater less].freeze

  attr_reader :ticker, :kind, :floor, :cap

  def initialize(ticker:, kind:, floor:, cap:)
    raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind)

    @ticker = ticker
    @kind = kind
    @floor = floor
    @cap = cap
  end

  def status_given(running_low)
    return :open if running_low.nil?

    degrees = running_low.round

    case kind
    when :between
      (degrees < floor) ? :refuted : :open
    when :greater
      # "72 or above" with floor 71 resolves YES only if the min stays above
      # 71. Reaching 71 kills it, and the min can never climb back.
      (degrees <= floor) ? :refuted : :open
    when :less
      # "63 or below" with cap 64 is settled the moment the min drops under 64.
      (degrees < cap) ? :confirmed : :open
    end
  end

  def settled_value_cents(running_low)
    case status_given(running_low)
    when :refuted then 0
    when :confirmed then 100
    end
  end

  def self.from_api(market)
    kind = market["strike_type"].to_s.to_sym
    return nil unless KINDS.include?(kind)

    new(ticker: market["ticker"], kind: kind,
      floor: market["floor_strike"]&.to_f, cap: market["cap_strike"]&.to_f)
  end
end
