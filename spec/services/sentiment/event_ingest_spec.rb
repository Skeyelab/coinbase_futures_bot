# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::EventIngest do
  def attrs_for(hash:, source: "oilprice_rss", **overrides)
    {
      source: source,
      symbol: "OIL-USD",
      url: "https://example.test/#{hash}",
      title: "Black Sea port goes quiet",
      published_at: 2.hours.ago.utc,
      raw_text_hash: hash,
      meta: {}
    }.merge(overrides)
  end

  it "stores events it has not seen before" do
    result = described_class.call([attrs_for(hash: "a1")])

    expect(SentimentEvent.count).to eq(1)
    expect(result.inserted).to eq(1)
  end

  # The defect this class exists for: RSS re-serves an item for as long as it
  # sits in the feed window, and the old per-item upsert rewrote created_at on
  # every poll — so ingestion time drifted forward and #446's inflow metric
  # counted re-polls as fresh arrivals.
  it "does not rewrite the ingestion timestamp of an event it already stored" do
    first_seen = 3.days.ago.utc.change(usec: 0)
    SentimentEvent.create!(attrs_for(hash: "a1").merge(created_at: first_seen, updated_at: first_seen))

    described_class.call([attrs_for(hash: "a1")])

    expect(SentimentEvent.count).to eq(1)
    expect(SentimentEvent.first.created_at.utc).to eq(first_seen)
  end

  it "leaves an already-scored event untouched" do
    SentimentEvent.create!(attrs_for(hash: "a1").merge(score: 0.42))

    described_class.call([attrs_for(hash: "a1")])

    expect(SentimentEvent.first.score).to eq(0.42)
  end

  it "counts an already-stored event as skipped rather than inserted" do
    SentimentEvent.create!(attrs_for(hash: "a1"))

    result = described_class.call([attrs_for(hash: "a1"), attrs_for(hash: "a2")])

    expect(result.inserted).to eq(1)
    expect(result.skipped).to eq(1)
  end

  # The same article served by two pages of one feed arrives twice in a single
  # batch; insert_all raises on a duplicate unique key within its own payload.
  it "tolerates the same event appearing twice in one batch" do
    expect {
      described_class.call([attrs_for(hash: "a1"), attrs_for(hash: "a1")])
    }.not_to raise_error

    expect(SentimentEvent.count).to eq(1)
  end

  # The unique key is (source, raw_text_hash) — the same story from two feeds is
  # two legitimate rows, and must not be collapsed.
  it "keeps the same content hash from different sources" do
    described_class.call([
      attrs_for(hash: "a1", source: "oilprice_rss"),
      attrs_for(hash: "a1", source: "rigzone_rss")
    ])

    expect(SentimentEvent.count).to eq(2)
  end
end
