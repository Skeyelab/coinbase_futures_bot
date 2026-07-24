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
end
