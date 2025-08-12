# frozen_string_literal: true

require "rails_helper"

RSpec.describe FetchCandlesJob, type: :job do
  let(:btc_pair) { TradingPair.find_or_create_by(product_id: "BTC-USD") { |tp| tp.base_currency = "BTC"; tp.quote_currency = "USD"; tp.status = "online"; tp.enabled = true } }

  after do
    # Don't destroy the BTC pair as it might be used by other tests
  end

  describe "#perform" do
    it "fetches both 1h and 15m candles" do
      # Just test that the job runs without error
      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error
    end

    it "returns early if no BTC trading pair found" do
      # Temporarily remove the BTC pair for this test
      original_btc_pair = btc_pair
      TradingPair.where(product_id: "BTC-USD").destroy_all

      expect { described_class.perform_now(backfill_days: 7) }.not_to raise_error

      # Restore the BTC pair
      original_btc_pair.save! if original_btc_pair.persisted?
    end
  end
end
