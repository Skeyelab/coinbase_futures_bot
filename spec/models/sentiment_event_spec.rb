require "rails_helper"

RSpec.describe SentimentEvent, type: :model do
  it "validates presence and uniqueness of raw_text_hash scoped to source" do
    e1 = described_class.create!(source: "cryptopanic", published_at: Time.now.utc, raw_text_hash: "abc")
    dup = described_class.new(source: "cryptopanic", published_at: Time.now.utc, raw_text_hash: "abc")
    expect(dup.valid?).to be(false)
    expect(dup.errors[:raw_text_hash]).to be_present

    other_source = described_class.new(source: "reddit", published_at: Time.now.utc, raw_text_hash: "abc")
    expect(other_source.valid?).to be(true)
  end

  it "scopes unscored and recent correctly" do
    older = described_class.create!(source: "cryptopanic", published_at: 2.hours.ago, raw_text_hash: "1", score: nil)
    newer = described_class.create!(source: "cryptopanic", published_at: 10.minutes.ago, raw_text_hash: "2", score: nil)
    scored = described_class.create!(source: "cryptopanic", published_at: 5.minutes.ago, raw_text_hash: "3", score: 0.2)

    expect(described_class.unscored).to include(older, newer)
    expect(described_class.unscored).not_to include(scored)

    expect(described_class.recent(1.hour.ago)).to include(newer, scored)
    expect(described_class.recent(1.hour.ago)).not_to include(older)
  end
end
