require "rails_helper"

RSpec.describe AggregateSentimentJob, type: :job do
  it "creates aggregates for 15m window and computes z_score" do
    now = Time.utc(2025, 8, 11, 12, 30, 0)
    win_start = now - 15.minutes

    # Seed some events within window
    3.times do |i|
      SentimentEvent.create!(source: "cryptopanic", symbol: "BTC-USD", published_at: win_start + i.minutes, raw_text_hash: "h#{i}", score: 0.5)
    end

    described_class.perform_now(now: now)

    agg = SentimentAggregate.where(symbol: "BTC-USD", window: "15m").order(window_end_at: :desc).first
    expect(agg).to be_present
    expect(agg.count).to eq(3)
    expect(agg.avg_score.to_f).to be_within(0.001).of(0.5)
    expect(agg.z_score).to be_between(-5, 5)
  end

  it "aggregates sentiment for enabled contract symbols beyond the crypto defaults" do
    create(:contract, product_id: "NOL-19JUN26-CDE", base_currency: "OIL", enabled: true)
    now = Time.utc(2025, 8, 11, 12, 30, 0)
    win_start = now - 15.minutes

    2.times do |i|
      SentimentEvent.create!(source: "oilprice", symbol: "OIL-USD", published_at: win_start + i.minutes, raw_text_hash: "oil#{i}", score: 0.3)
    end

    described_class.perform_now(now: now)

    agg = SentimentAggregate.where(symbol: "OIL-USD", window: "15m").order(window_end_at: :desc).first
    expect(agg).to be_present
    expect(agg.count).to eq(2)
    expect(agg.avg_score.to_f).to be_within(0.001).of(0.3)
  end

  it "excludes empty windows from the z-score baseline" do
    now = Time.utc(2025, 8, 11, 12, 30, 0)
    window_end = Time.utc(2025, 8, 11, 12, 30, 0)

    # Baseline history: mostly empty windows (count 0, avg 0) plus two real
    # windows averaging 0.3. Empty windows must not enter the mean/stddev.
    8.times do |i|
      SentimentAggregate.create!(symbol: "BTC-USD", window: "15m", window_end_at: window_end - (i + 3).hours,
        count: 0, avg_score: 0.0, weighted_score: 0.0, z_score: 0.0)
    end
    [0.2, 0.4].each_with_index do |avg, i|
      SentimentAggregate.create!(symbol: "BTC-USD", window: "15m", window_end_at: window_end - (i + 1).hours,
        count: 2, avg_score: avg, weighted_score: avg, z_score: 0.0)
    end

    # New window averages 0.3 — equal to the real-window baseline mean, so a
    # correct z-score is ~0. With empty windows polluting the baseline it spikes.
    2.times do |i|
      SentimentEvent.create!(source: "cryptopanic", symbol: "BTC-USD", published_at: (window_end - 15.minutes) + i.minutes,
        raw_text_hash: "zb#{i}", score: 0.3)
    end

    described_class.perform_now(now: now)

    agg = SentimentAggregate.where(symbol: "BTC-USD", window: "15m", window_end_at: window_end).first
    expect(agg.avg_score.to_f).to be_within(0.001).of(0.3)
    expect(agg.z_score.to_f).to be_within(0.05).of(0.0)
  end
end
