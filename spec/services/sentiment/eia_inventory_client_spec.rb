# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::EiaInventoryClient, type: :service do
  subject(:client) { described_class.new(api_key: "test-key") }

  # EIA API v2 returns weekly crude stock levels (thousand barrels), newest first.
  def rows(latest:, previous:)
    [
      {"period" => "2026-07-10", "value" => latest},
      {"period" => "2026-07-03", "value" => previous}
    ]
  end

  describe "#normalize" do
    it "labels a week-over-week stock decline as an inventory draw (bullish for oil)" do
      events = client.send(:normalize, rows(latest: 420_000, previous: 425_000))

      evt = events.first
      expect(evt[:symbol]).to eq("OIL-USD")
      expect(evt[:source]).to eq("eia_inventory")
      expect(evt[:title]).to match(/inventory draw/i)
    end

    it "labels a week-over-week stock rise as an inventory build (bearish for oil)" do
      events = client.send(:normalize, rows(latest: 428_000, previous: 425_000))

      expect(events.first[:title]).to match(/inventory build/i)
    end

    it "emits a distinct hash per weekly period" do
      a = client.send(:normalize, rows(latest: 420_000, previous: 425_000)).first
      b = client.send(:normalize, [{"period" => "2026-07-17", "value" => 418_000}, {"period" => "2026-07-10", "value" => 420_000}]).first
      expect(a[:raw_text_hash]).not_to eq(b[:raw_text_hash])
    end
  end

  describe "#fetch_recent" do
    it "returns [] when no api key is configured" do
      expect(described_class.new(api_key: nil).fetch_recent).to eq([])
    end

    it "normalizes the latest weekly change from the API rows" do
      allow(client).to receive(:fetch_rows).and_return(rows(latest: 420_000, previous: 425_000))

      events = client.fetch_recent

      expect(events.size).to eq(1)
      expect(events.first[:title]).to match(/inventory draw/i)
    end
  end

  # The whole point of phrasing the title as "inventory draw"/"build" is that the
  # existing oil lexicon scores it with no special-casing.
  describe "scoring round-trip through the oil lexicon" do
    let(:scorer) { Sentiment::SimpleLexiconScorer.for("OIL-USD") }

    it "scores a draw event bullish" do
      title = client.send(:normalize, rows(latest: 420_000, previous: 425_000)).first[:title]
      score, = scorer.score(title)
      expect(score).to be > 0
    end

    it "scores a build event bearish" do
      title = client.send(:normalize, rows(latest: 428_000, previous: 425_000)).first[:title]
      score, = scorer.score(title)
      expect(score).to be < 0
    end
  end
end
