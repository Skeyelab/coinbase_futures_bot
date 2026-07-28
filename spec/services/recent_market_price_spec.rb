# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecentMarketPrice do
  describe ".for_product" do
    let(:product_id) { "BIT-27AUG25-CDE" }

    it "returns the most recent tick price when fresh" do
      create(:tick, product_id: product_id, price: 49_000, observed_at: 4.minutes.ago)
      create(:tick, product_id: product_id, price: 50_000, observed_at: 1.minute.ago)
      create(:candle, :one_minute, symbol: product_id, close: 51_000, timestamp: 1.minute.ago)

      expect(described_class.for_product(product_id)).to eq(50_000)
    end

    it "falls back to the latest recent 1m candle close" do
      create(:tick, product_id: product_id, price: 49_000, observed_at: 10.minutes.ago)
      create(:candle, :one_minute, symbol: product_id, close: 50_500, timestamp: 2.minutes.ago)

      expect(described_class.for_product(product_id)).to eq(50_500)
    end

    it "returns nil when no recent tick or 1m candle exists" do
      create(:tick, product_id: product_id, price: 49_000, observed_at: 10.minutes.ago)
      create(:candle, :one_minute, symbol: product_id, close: 50_500, timestamp: 10.minutes.ago)

      expect(described_class.for_product(product_id)).to be_nil
    end
  end

  # The dark-feed fallback used to live in three call sites. These assert the
  # decision itself, so it cannot silently diverge again.
  describe ".mark" do
    let(:product_id) { "BIT-27AUG25-CDE" }
    let(:position) { create(:position, product_id: product_id, entry_price: 48_000, status: "OPEN") }

    it "reports a fresh price as a live mark" do
      create(:tick, product_id: product_id, price: 50_000, observed_at: 1.minute.ago)

      mark = described_class.mark(position)

      expect(mark.price).to eq(50_000)
      expect(mark.live?).to be true
    end

    it "falls back to the position's entry price when the feed is dark" do
      create(:tick, product_id: product_id, price: 50_000, observed_at: 10.minutes.ago)

      mark = described_class.mark(position)

      expect(mark.price).to eq(48_000)
      expect(mark.live?).to be false
    end

    it "warns on the fallback when given a logger, so a dark feed is never silent" do
      logger = instance_double(Logger)
      expect(logger).to receive(:warn).with(/No recent price data for #{product_id}, using entry price/)

      described_class.mark(position, logger: logger)
    end

    it "stays silent on the fallback when given no logger" do
      expect { described_class.mark(position) }.not_to raise_error
    end
  end
end
