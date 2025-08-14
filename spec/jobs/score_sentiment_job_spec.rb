require "rails_helper"

RSpec.describe ScoreSentimentJob, type: :job do
  it "scores unscored events and sets confidence" do
    e1 = SentimentEvent.create!(source: "cryptopanic", published_at: Time.now.utc, raw_text_hash: "a", title: "bullish breakout rally")
    e2 = SentimentEvent.create!(source: "cryptopanic", published_at: Time.now.utc, raw_text_hash: "b", title: "bearish crash dump")

    described_class.perform_now

    e1.reload
    e2.reload
    expect(e1.score).to be_between(-1, 1)
    expect(e1.confidence).to be_between(0, 1)
    expect(e2.score).to be_between(-1, 1)
    expect(e2.confidence).to be_between(0, 1)
  end
end
