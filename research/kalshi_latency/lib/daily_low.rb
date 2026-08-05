require_relative "daily_extreme"

# The day's running MINIMUM temperature.
#
# Mirror of DailyHigh: a minimum only ratchets downward, so once the low
# reaches a level the outcome is fixed and cannot reverse.
#
# Worth pairing with highs for a reason beyond doubling the market count: lows
# are set around dawn and highs mid-to-late afternoon, so together they cover
# opposite halves of the day instead of clustering in the same hours. Before
# adding lows the scanner had nothing to find before noon.
class DailyLow
  include DailyExtreme

  private

  def direction = :min
end
