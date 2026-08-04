require "date"
require "tzinfo"

# The day's running maximum temperature, bucketed by the station's LOCAL
# calendar day.
#
# Local time is not a detail. Kalshi settles on the NWS daily climate report
# for the local day, so a 9pm reading in New York belongs to that day even
# though its UTC stamp already says tomorrow. Bucketing in UTC would silently
# move every late-evening high onto the wrong day, which would corrupt both.
class DailyHigh
  def initialize(observations, time_zone:)
    @observations = observations
    @zone = TZInfo::Timezone.get(time_zone)
  end

  def for_date(local_date)
    temps = @observations
      .reject { |o| o[:temp_f].nil? }
      .select { |o| local_date_of(o[:at]) == local_date }
      .map { |o| o[:temp_f] }

    temps.max
  end

  private

  def local_date_of(utc_time)
    @zone.to_local(utc_time.getutc).to_date
  end
end
