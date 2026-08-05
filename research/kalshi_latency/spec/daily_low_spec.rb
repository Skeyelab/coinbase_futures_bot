require "time"
require_relative "../lib/daily_low"

RSpec.describe DailyLow do
  # The mirror of DailyHigh. A daily MINIMUM only ratchets DOWNWARD, so once
  # the low reaches a level it can never come back up -- exactly the same
  # irreversibility that makes a daily high tradeable, pointing the other way.
  #
  # Lows are set around dawn and highs mid-afternoon, so together they cover
  # opposite halves of the day rather than piling into the same hours.
  def obs(utc, temp_f)
    {at: Time.parse(utc), temp_f: temp_f}
  end

  describe "#for_date" do
    it "takes the coldest reading of the local day" do
      readings = [obs("2026-08-04T09:51:00Z", 74.0),
        obs("2026-08-04T10:51:00Z", 68.0),
        obs("2026-08-04T18:51:00Z", 88.0)]

      low = described_class.new(readings, time_zone: "America/New_York")

      expect(low.for_date(Date.new(2026, 8, 4))).to eq(68.0)
    end

    # The direction is the whole difference between this and DailyHigh. Taking
    # the max here would report the afternoon peak as the day's low and refute
    # every contract backwards.
    it "is not fooled by a hot afternoon" do
      readings = [obs("2026-08-04T10:51:00Z", 70.0), obs("2026-08-04T20:51:00Z", 99.0)]

      low = described_class.new(readings, time_zone: "America/New_York")

      expect(low.for_date(Date.new(2026, 8, 4))).to eq(70.0)
    end

    it "keeps a late-evening reading on the local day it belongs to" do
      readings = [obs("2026-08-05T02:51:00Z", 61.0)]

      low = described_class.new(readings, time_zone: "America/New_York")

      expect(low.for_date(Date.new(2026, 8, 4))).to eq(61.0)
      expect(low.for_date(Date.new(2026, 8, 5))).to be_nil
    end

    it "ignores readings the station failed to report" do
      readings = [obs("2026-08-04T09:51:00Z", nil), obs("2026-08-04T10:51:00Z", 66.0)]

      expect(described_class.new(readings, time_zone: "America/New_York")
        .for_date(Date.new(2026, 8, 4))).to eq(66.0)
    end
  end

  describe "#support_for" do
    it "counts the observations standing behind the coldest reading" do
      readings = [obs("2026-08-04T09:51:00Z", 68.0), obs("2026-08-04T10:00:00Z", 68.0),
        obs("2026-08-04T11:51:00Z", 74.0)]

      expect(described_class.new(readings, time_zone: "America/New_York")
        .support_for(Date.new(2026, 8, 4))).to eq(2)
    end

    it "reports a lone cold spike as exactly that" do
      readings = [obs("2026-08-04T09:51:00Z", 70.0), obs("2026-08-04T10:00:00Z", 61.0),
        obs("2026-08-04T11:00:00Z", 72.0)]

      expect(described_class.new(readings, time_zone: "America/New_York")
        .support_for(Date.new(2026, 8, 4))).to eq(1)
    end
  end
end
