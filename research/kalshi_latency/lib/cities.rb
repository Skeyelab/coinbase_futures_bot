require "tzinfo"

# Kalshi daily-high series paired with the NWS station that settles them.
#
# Each station was read out of the market's own rules_primary text, not
# guessed. Getting this wrong is silent and expensive: Chicago settles on
# Midway (KMDW), not O'Hare, and trading against the wrong station would look
# like a working edge right up until settlement.
#
# Verified 2026-08-04 against live rules text:
#   KXHIGHNY   "Central Park, New York"
#   KXHIGHCHI  "Chicago Midway, IL"
#   KXHIGHMIA  "Miami International Airport"
#   KXHIGHDEN  "Denver, CO"                     <- vaguest; KDEN is the official climate site
#   KXHIGHLAX  "Los Angeles Airport, CA"
#   KXHIGHAUS  "Austin Bergstrom"
#   KXHIGHPHIL "Philadelphia International Airport"
module Cities
  # verified: the market's own rules_primary NAMES the station. Only these may
  # produce tradeable opportunities.
  #
  # The twelve added 2026-08-04 say only "at Atlanta", "at Phoenix" -- no
  # station at all. The stations below are the obvious primary climate site for
  # each city, which is very likely right and is NOT evidence. Chicago settling
  # on Midway rather than O'Hare is exactly this class of error.
  #
  # An attempt to verify them against already-settled markets FAILED to
  # discriminate: every retrievable settled market had resolved NO, giving only
  # a loose upper bound, and all three candidate DC stations "matched" it. They
  # are promoted only once a day of their own recorded predictions scores clean
  # against settlement.
  ALL = [
    # --- station quoted in the rules --------------------------------------
    {series: "KXHIGHNY", station: "KNYC", time_zone: "America/New_York", label: "NYC", verified: true},
    {series: "KXHIGHCHI", station: "KMDW", time_zone: "America/Chicago", label: "Chicago", verified: true},
    {series: "KXHIGHMIA", station: "KMIA", time_zone: "America/New_York", label: "Miami", verified: true},
    {series: "KXHIGHDEN", station: "KDEN", time_zone: "America/Denver", label: "Denver", verified: true},
    {series: "KXHIGHLAX", station: "KLAX", time_zone: "America/Los_Angeles", label: "LA", verified: true},
    {series: "KXHIGHAUS", station: "KAUS", time_zone: "America/Chicago", label: "Austin", verified: true},
    {series: "KXHIGHPHIL", station: "KPHL", time_zone: "America/New_York", label: "Philadelphia", verified: true},

    # --- station INFERRED, prediction-only until settlement confirms it -----
    {series: "KXHIGHTATL", station: "KATL", time_zone: "America/New_York", label: "Atlanta", verified: false},
    {series: "KXHIGHTBOS", station: "KBOS", time_zone: "America/New_York", label: "Boston", verified: false},
    {series: "KXHIGHTDC", station: "KDCA", time_zone: "America/New_York", label: "DC", verified: false},
    {series: "KXHIGHTDAL", station: "KDFW", time_zone: "America/Chicago", label: "Dallas", verified: false},
    {series: "KXHIGHTMIN", station: "KMSP", time_zone: "America/Chicago", label: "Minneapolis", verified: false},
    {series: "KXHIGHTNOLA", station: "KMSY", time_zone: "America/Chicago", label: "New Orleans", verified: false},
    {series: "KXHIGHTOKC", station: "KOKC", time_zone: "America/Chicago", label: "Oklahoma City", verified: false},
    {series: "KXHIGHTSATX", station: "KSAT", time_zone: "America/Chicago", label: "San Antonio", verified: false},
    # Arizona does not observe daylight saving. America/Denver would put the
    # local day boundary an hour out all summer and reassign late peaks.
    {series: "KXHIGHTPHX", station: "KPHX", time_zone: "America/Phoenix", label: "Phoenix", verified: false},
    {series: "KXHIGHTLV", station: "KLAS", time_zone: "America/Los_Angeles", label: "Las Vegas", verified: false},
    {series: "KXHIGHTSEA", station: "KSEA", time_zone: "America/Los_Angeles", label: "Seattle", verified: false},
    {series: "KXHIGHTSFO", station: "KSFO", time_zone: "America/Los_Angeles", label: "San Francisco", verified: false}
  ].freeze

  # Daily-LOW series. The observable is a running MINIMUM, so these use
  # LowTempMarket, whose settleable side is mirrored.
  #
  # Worth having for TIMING, not just count: lows are set around dawn and highs
  # mid-afternoon, so together they cover opposite halves of the day. Before
  # these the scanner had nothing to find before noon.
  #
  # All UNVERIFIED. Their rules say only "at Denver", "at Chicago" -- and note
  # that KXLOWTCHI is a DIFFERENT SERIES from KXHIGHCHI, which does name
  # Midway. Sharing a city name is not evidence of sharing a station.
  LOWS = [
    {series: "KXLOWTDEN", station: "KDEN", time_zone: "America/Denver", label: "Denver LOW", verified: false},
    {series: "KXLOWTATL", station: "KATL", time_zone: "America/New_York", label: "Atlanta LOW", verified: false},
    {series: "KXLOWTCHI", station: "KMDW", time_zone: "America/Chicago", label: "Chicago LOW", verified: false},
    {series: "KXLOWTMIN", station: "KMSP", time_zone: "America/Chicago", label: "Minneapolis LOW", verified: false},
    {series: "KXLOWTOKC", station: "KOKC", time_zone: "America/Chicago", label: "OKC LOW", verified: false},
    {series: "KXLOWTSATX", station: "KSAT", time_zone: "America/Chicago", label: "San Antonio LOW", verified: false},
    {series: "KXLOWTSFO", station: "KSFO", time_zone: "America/Los_Angeles", label: "SF LOW", verified: false},
    {series: "KXLOWTLV", station: "KLAS", time_zone: "America/Los_Angeles", label: "Las Vegas LOW", verified: false},
    {series: "KXLOWTPHIL", station: "KPHL", time_zone: "America/New_York", label: "Philadelphia LOW", verified: false}
  ].freeze

  def self.each(&block)
    ALL.each(&block)
  end

  def self.verified
    ALL.select { |c| c[:verified] }
  end
end
