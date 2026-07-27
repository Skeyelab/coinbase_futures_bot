# frozen_string_literal: true

require "rails_helper"

RSpec.describe PredictivenessSnapshotJob do
  let(:t0) { Time.utc(2026, 7, 1, 0, 0, 0) }

  def candle(hour, close, symbol:)
    Candle.create!(symbol: symbol, timeframe: "1h", timestamp: t0 + hour.hours,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  def agg(hour, z, symbol: "OIL-USD")
    SentimentAggregate.create!(symbol: symbol, window: "1h", window_end_at: t0 + hour.hours,
      z_score: z, avg_score: 0, weighted_score: 0, count: 3)
  end

  it "computes predictiveness per enabled sentiment symbol and stores it in bot_runtime_stats" do
    create(:contract, product_id: "NOL-19AUG26-CDE", base_currency: "OIL", enabled: true)
    price = "NOL-19AUG26-CDE"
    (0..29).each { |h| candle(h, 90 + h, symbol: price) }
    [[0, 2.0], [1, -2.0], [2, 2.0], [3, -2.0]].each { |h, z| agg(h, z) }

    described_class.new.perform(now: t0 + 30.hours)

    stat = BotRuntimeStat.find_by(key: "indicators:predictiveness")
    expect(stat).to be_present
    expect(stat.value["computed_at"]).to be_present

    oil = stat.value["symbols"].find { |s| s["sentiment_symbol"] == "OIL-USD" }
    expect(oil["price_symbol"]).to eq(price) # resolved via ContractSymbolMapper
    expect(oil["horizons"].keys).to match_array(%w[1 4 24])
    expect(oil["horizons"]["4"]).to include("correlation", "hit_rate", "n", "signal_count")
    expect(oil["maturity"]).to eq("low") # tiny sample
  end

  it "skips symbols with no resolvable price series" do
    create(:contract, product_id: "NOL-19AUG26-CDE", base_currency: "OIL", enabled: true)
    # No candles anywhere -> price_symbol_for returns nil -> OIL is skipped, no crash.
    described_class.new.perform(now: t0)

    stat = BotRuntimeStat.find_by(key: "indicators:predictiveness")
    expect(stat.value["symbols"]).to eq([])
  end

  # Issue #468: this is the exact shape of the 2026-07-27 production reading —
  # six days of hourly aggregates producing n=134, which the old row-count
  # thresholds labelled "high". A dense week is not a seasoned dataset, and
  # oil read a 0.25 hit rate under that label.
  it "refuses to call six days of dense hourly data seasoned" do
    create(:contract, product_id: "NOL-19AUG26-CDE", base_currency: "OIL", enabled: true)
    price = "NOL-19AUG26-CDE"
    hours = 6 * 24
    (0..(hours + 24)).each { |h| candle(h, 90 + (h % 7), symbol: price) }
    (0..hours).each { |h| agg(h, (h.even? ? 2.0 : -2.0)) }

    described_class.new.perform(now: t0 + (hours + 24).hours)

    oil = BotRuntimeStat.find_by(key: "indicators:predictiveness")
      .value["symbols"].find { |s| s["sentiment_symbol"] == "OIL-USD" }
    headline = oil["horizons"]["4"]

    expect(headline["n"]).to be > 100          # plenty of rows...
    expect(headline["effective_n"]).to be < 40 # ...but few independent ones
    expect(headline["span_days"]).to be_within(0.1).of(6.0)
    expect(oil["maturity"]).not_to eq("high")
  end

  it "surfaces the independent count and span behind every horizon" do
    create(:contract, product_id: "NOL-19AUG26-CDE", base_currency: "OIL", enabled: true)
    (0..29).each { |h| candle(h, 90 + h, symbol: "NOL-19AUG26-CDE") }
    (0..20).each { |h| agg(h, 2.0) }

    described_class.new.perform(now: t0 + 30.hours)

    oil = BotRuntimeStat.find_by(key: "indicators:predictiveness")
      .value["symbols"].find { |s| s["sentiment_symbol"] == "OIL-USD" }

    oil["horizons"].each_value do |h|
      expect(h).to include("effective_n", "effective_signal_count", "span_days")
    end
    # A longer horizon consumes the same span in bigger bites.
    expect(oil["horizons"]["24"]["effective_n"]).to be < oil["horizons"]["1"]["effective_n"]
  end
end
