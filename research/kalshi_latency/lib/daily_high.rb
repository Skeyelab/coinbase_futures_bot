require_relative "daily_extreme"

# The day's running MAXIMUM temperature. See DailyExtreme for the shared
# ratchet, the local-day bucketing, and why corroboration is tracked.
class DailyHigh
  include DailyExtreme

  private

  def direction = :max
end
