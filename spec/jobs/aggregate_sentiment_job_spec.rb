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
end
