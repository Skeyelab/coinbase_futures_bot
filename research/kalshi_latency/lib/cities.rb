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
  ALL = [
    {series: "KXHIGHNY", station: "KNYC", time_zone: "America/New_York", label: "NYC"},
    {series: "KXHIGHCHI", station: "KMDW", time_zone: "America/Chicago", label: "Chicago"},
    {series: "KXHIGHMIA", station: "KMIA", time_zone: "America/New_York", label: "Miami"},
    {series: "KXHIGHDEN", station: "KDEN", time_zone: "America/Denver", label: "Denver"},
    {series: "KXHIGHLAX", station: "KLAX", time_zone: "America/Los_Angeles", label: "LA"},
    {series: "KXHIGHAUS", station: "KAUS", time_zone: "America/Chicago", label: "Austin"},
    {series: "KXHIGHPHIL", station: "KPHL", time_zone: "America/New_York", label: "Philadelphia"}
  ].freeze

  def self.each(&block)
    ALL.each(&block)
  end
end
