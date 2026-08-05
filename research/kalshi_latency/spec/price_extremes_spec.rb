require "time"
require_relative "../lib/price_extremes"

RSpec.describe PriceExtremes do
  # Coinbase candles: [start_epoch, low, high, open, close, volume]
  def candle(epoch, low, high)
    {"start" => epoch.to_s, "low" => low.to_s, "high" => high.to_s}
  end

  let(:t0) { Time.utc(2026, 8, 1).to_i }

  describe ".from_candles" do
    # A one-touch resolves on whether price EVER reached a level, so the extreme
    # must come from candle highs and lows -- never closes. A wick that touched
    # $59,900 and closed at $61,000 still settles the market.
    it "takes the extremes from wicks, not closes" do
      candles = [candle(t0, 60_500, 61_000), candle(t0 + 3600, 59_900, 60_800)]

      extremes = described_class.from_candles(candles)

      expect(extremes[:min]).to eq(59_900.0)
      expect(extremes[:max]).to eq(61_000.0)
    end

    it "counts the bars it actually used" do
      candles = [candle(t0, 60_500, 61_000), candle(t0 + 3600, 59_900, 60_800)]

      expect(described_class.from_candles(candles)[:bars]).to eq(2)
    end

    # A zero or missing price is a gap in the feed, not a touch of $0. Letting
    # one through would confirm every below-touch market in existence.
    it "ignores empty or zero bars rather than treating them as a touch" do
      candles = [candle(t0, 60_500, 61_000), candle(t0 + 3600, 0, 0), {"low" => "", "high" => ""}]

      extremes = described_class.from_candles(candles)

      expect(extremes[:min]).to eq(60_500.0)
      expect(extremes[:bars]).to eq(1)
    end

    it "has no extremes without data" do
      expect(described_class.from_candles([])[:min]).to be_nil
      expect(described_class.from_candles(nil)[:max]).to be_nil
    end
  end

  describe ".coarse_enough" do
    # Asking for ONE_HOUR over a month silently truncates to the most recent
    # ~300 hours and reports a minimum that never happened in the real window.
    it "picks a granularity whose whole window fits inside the request cap" do
      month = described_class.coarse_enough(t0, t0 + 31 * 86_400)
      seconds = described_class::GRANULARITY_SECONDS.fetch(month)

      expect((31 * 86_400) / seconds).to be <= described_class::MAX_CANDLES * 12
    end

    it "stays fine-grained on a short window" do
      expect(described_class.coarse_enough(t0, t0 + 3600)).to eq("ONE_MINUTE")
    end
  end
end
