require_relative "../lib/nws_station"

RSpec.describe NwsStation do
  # The default observation window has to cover a WHOLE LOCAL DAY, and station
  # cadence varies wildly: KNYC reports hourly, KOKC and KAUS every 5 minutes.
  #
  # A 24-observation limit is 24 hours at KNYC but only TWO HOURS at KOKC. That
  # was invisible while we only tracked daily HIGHS scanned in the afternoon --
  # the high was always inside the last two hours by luck. Daily LOWS are set
  # at dawn and fell straight outside the window: OKC reported a "low" of
  # 100.4F, which was near its high.
  #
  # 288 five-minute observations is a full day, so the default must exceed that
  # with room for the local-day boundary straddling UTC.
  it "defaults to a window that covers a full day even at 5-minute cadence" do
    expect(described_class::DEFAULT_LIMIT).to be >= 350
  end

  it "still lets a caller ask for fewer" do
    expect(described_class.instance_method(:observations).parameters)
      .to include([:key, :limit])
  end
end
