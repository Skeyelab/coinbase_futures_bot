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

  it "scores oil events with the oil lexicon so supply cuts read bullish" do
    evt = SentimentEvent.create!(source: "oilprice", symbol: "OIL-USD", published_at: Time.now.utc,
      raw_text_hash: "oil-cut", title: "OPEC agrees production cut")

    described_class.perform_now

    expect(evt.reload.score).to be > 0
  end

  it "scores the article description, not only the title" do
    evt = SentimentEvent.create!(source: "coindesk", symbol: "BTC-USD", published_at: Time.now.utc,
      raw_text_hash: "desc-only", title: "Market update", meta: {"description" => "bullish breakout rally surge"})

    described_class.perform_now

    expect(evt.reload.score).to be > 0
  end
end
