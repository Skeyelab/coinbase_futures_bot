# A market on a CUMULATIVE COUNT — Trump posts in a week, launches in a month,
# cases in a year.
#
# Same ratchet as a daily maximum temperature: the observable only rises, so
# passing a bucket's ceiling refutes it permanently and reaching a floor
# confirms permanently.
#
# Kept separate from TempMarket for one reason: TempMarket ROUNDS to whole
# degrees before comparing, because weather settles on a whole-degree climate
# report. A count is already an integer, and rounding it would shift every
# boundary by half a post.
class CountMarket
  KINDS = %i[between greater less].freeze

  attr_reader :ticker, :kind, :floor, :cap

  def initialize(ticker:, kind:, floor:, cap:)
    raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind)

    @ticker = ticker
    @kind = kind
    @floor = floor
    @cap = cap
  end

  def status_given(count)
    return :open if count.nil?

    case kind
    when :between
      (count > cap) ? :refuted : :open
    when :less
      (count > cap) ? :refuted : :open
    when :greater
      # "above 240" resolves YES the moment the count exceeds 240, and a count
      # cannot fall back.
      (count > floor) ? :confirmed : :open
    end
  end

  def settled_value_cents(count)
    case status_given(count)
    when :refuted then 0
    when :confirmed then 100
    end
  end

  def self.from_api(market)
    kind = market["strike_type"].to_s.to_sym
    return nil unless KINDS.include?(kind)

    new(ticker: market["ticker"], kind: kind,
      floor: market["floor_strike"]&.to_i, cap: market["cap_strike"]&.to_i)
  end
end
