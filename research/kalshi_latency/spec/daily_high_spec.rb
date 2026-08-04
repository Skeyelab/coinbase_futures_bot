require "time"
require_relative "../lib/daily_high"

RSpec.describe DailyHigh do
  # NWS stamps observations in UTC. Kalshi settles on the station's LOCAL
  # calendar day, so bucketing has to happen in local time or a late-evening
  # reading lands on tomorrow and corrupts both days.
  def obs(utc, temp_f)
    {at: Time.parse(utc), temp_f: temp_f}
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
