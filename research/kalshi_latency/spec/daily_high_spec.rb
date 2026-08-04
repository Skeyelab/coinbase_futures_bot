require "time"
require_relative "../lib/daily_high"

RSpec.describe DailyHigh do
  # NWS stamps observations in UTC. Kalshi settles on the station's LOCAL
  # calendar day, so bucketing has to happen in local time or a late-evening
  # reading lands on tomorrow and corrupts both days.
  def obs(utc, temp_f)
    {at: Time.parse(utc), temp_f: temp_f}
  end

  # Measured 2026-08-04: how well-corroborated a peak is predicts whether the
  # book agrees it is real, and MARGIN does not.
  #
  #   KMIA 89.6F, 37 observations at the peak -> market agreed (0%)
  #   KAUS 98.6F,  4 observations             -> market agreed (0%)
  #   KLAX 78.8F,  1 observation              -> market disagreed (76%)
  #
  # LAX had the WIDEST margin over the rounding boundary of the three and was
  # the one the market disputed. A lone 5-minute tick is noise; a peak held
  # across several is a fact.
  describe "#support_for" do
    it "counts how many observations stand behind the day's peak" do
      readings = [obs("2026-08-04T18:00:00Z", 96.8), obs("2026-08-04T18:05:00Z", 98.6),
        obs("2026-08-04T18:10:00Z", 98.6), obs("2026-08-04T18:15:00Z", 96.8)]

      high = described_class.new(readings, time_zone: "America/Chicago")

      expect(high.support_for(Date.new(2026, 8, 4))).to eq(2)
    end

    it "reports a lone spike as exactly that" do
      readings = [obs("2026-08-04T18:00:00Z", 77.0), obs("2026-08-04T18:05:00Z", 78.8),
        obs("2026-08-04T18:10:00Z", 75.2)]

      high = described_class.new(readings, time_zone: "America/Los_Angeles")

      expect(high.support_for(Date.new(2026, 8, 4))).to eq(1)
    end

    it "counts only the local day, like the peak itself" do
      readings = [obs("2026-08-05T02:00:00Z", 90.0), obs("2026-08-04T18:00:00Z", 90.0)]

      high = described_class.new(readings, time_zone: "America/New_York")

      # 02:00Z Aug 5 is 22:00 Aug 4 in New York, so both belong to Aug 4.
      expect(high.support_for(Date.new(2026, 8, 4))).to eq(2)
      expect(high.support_for(Date.new(2026, 8, 5))).to eq(0)
    end

    it "has no support to report on a day with no readings" do
      expect(described_class.new([], time_zone: "America/New_York")
        .support_for(Date.new(2026, 8, 4))).to eq(0)
    end
  end

  describe "#for_date" do
    it "takes the hottest reading of the local day" do
      readings = [
        obs("2026-08-04T14:51:00Z", 79.0),
        obs("2026-08-04T18:51:00Z", 84.0),
        obs("2026-08-04T20:51:00Z", 82.0)
      ]

      high = described_class.new(readings, time_zone: "America/New_York")

      expect(high.for_date(Date.new(2026, 8, 4))).to eq(84.0)
    end

    # 02:51Z on Aug 5 is 22:51 on Aug 4 in New York. Bucketing in UTC would
    # hand this reading to the wrong day and hide a real daily high.
    it "keeps a late-evening reading on the local day it belongs to" do
      readings = [obs("2026-08-05T02:51:00Z", 91.0)]

      high = described_class.new(readings, time_zone: "America/New_York")

      expect(high.for_date(Date.new(2026, 8, 4))).to eq(91.0)
      expect(high.for_date(Date.new(2026, 8, 5))).to be_nil
    end

    it "ignores readings the station failed to report" do
      readings = [obs("2026-08-04T14:51:00Z", nil), obs("2026-08-04T15:51:00Z", 77.0)]

      high = described_class.new(readings, time_zone: "America/New_York")

      expect(high.for_date(Date.new(2026, 8, 4))).to eq(77.0)
    end

    it "has no running high before the day's first reading" do
      high = described_class.new([], time_zone: "America/New_York")

      expect(high.for_date(Date.new(2026, 8, 4))).to be_nil
    end

    it "buckets each station in its own zone" do
      # 05:51Z Aug 5 is 22:51 Aug 4 in Los Angeles but 01:51 Aug 5 in New York.
      readings = [obs("2026-08-05T05:51:00Z", 88.0)]

      pacific = described_class.new(readings, time_zone: "America/Los_Angeles")
      eastern = described_class.new(readings, time_zone: "America/New_York")

      expect(pacific.for_date(Date.new(2026, 8, 4))).to eq(88.0)
      expect(eastern.for_date(Date.new(2026, 8, 4))).to be_nil
    end
  end
end
