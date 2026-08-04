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
    temps_on(local_date).max
  end

  # How many observations stand behind the day's peak.
  #
  # Measured 2026-08-04, this predicts whether the book agrees a peak is real,
  # and the margin over the rounding boundary does NOT:
  #
  #   KMIA 89.6F, 37 observations -> market agreed the bucket was dead
  #   KAUS 98.6F,  4 observations -> market agreed
  #   KLAX 78.8F,  1 observation  -> market disagreed at 76%, despite having
  #                                  the WIDEST margin of the three
  #
  # A lone 5-minute tick is noise. A peak held across several is a fact. The
  # model treats every maximum as definitive, so this is the number that says
  # how much to trust it.
  def support_for(local_date)
    temps = temps_on(local_date)
    peak = temps.max
    return 0 if peak.nil?

    temps.count { |t| t >= peak }
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
