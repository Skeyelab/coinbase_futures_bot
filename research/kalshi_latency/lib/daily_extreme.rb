require "date"
require "tzinfo"

# The day's running extreme, bucketed by the station's LOCAL calendar day.
#
# Shared by DailyHigh and DailyLow because the ratchet is the same shape
# pointing opposite ways: a maximum only rises, a minimum only falls, and
# either way the value cannot come back once it has moved.
#
# Local time is not a detail. Kalshi settles on the NWS daily climate report
# for the local day, so a 9pm reading in New York belongs to that day even
# though its UTC stamp already says tomorrow. Bucketing in UTC would silently
# move every late-evening extreme onto the wrong day and corrupt both.
module DailyExtreme
  def initialize(observations, time_zone:)
    @observations = observations
    @zone = TZInfo::Timezone.get(time_zone)
  end

  def for_date(local_date)
    temps_on(local_date).public_send(direction)
  end

  # How many observations stand behind the day's extreme.
  #
  # Measured 2026-08-04, this predicts whether the book agrees an extreme is
  # real, and the margin over the rounding boundary does NOT: KMIA with 37
  # observations and KAUS with 4 both matched the market, while KLAX with 1
  # disagreed at 76% despite having the widest margin of the three. The LAX
  # reading was later revised out of the feed entirely.
  def support_for(local_date)
    temps = temps_on(local_date)
    extreme = temps.public_send(direction)
    return 0 if extreme.nil?

    temps.count { |t| t == extreme }
  end

  private

  def temps_on(local_date)
    @observations
      .reject { |o| o[:temp_f].nil? }
      .select { |o| local_date_of(o[:at]) == local_date }
      .map { |o| o[:temp_f] }
  end

  def local_date_of(utc_time)
    @zone.to_local(utc_time.getutc).to_date
  end
end
