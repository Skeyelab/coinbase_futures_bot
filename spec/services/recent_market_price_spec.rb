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
end
