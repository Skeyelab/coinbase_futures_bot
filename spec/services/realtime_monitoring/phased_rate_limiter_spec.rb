# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealtimeMonitoring::PhasedRateLimiter do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:clock_time) { Time.utc(2026, 6, 8, 17, 0, 0) }
  subject(:limiter) { described_class.new(cache: cache, clock: -> { clock_time }) }

  describe "#due?" do
    it "allows the first call for a key in a new bucket" do
      expect(limiter.due?(key: "BTC-USD:BIT-31JUL26-CDE", interval_seconds: 60, cache_prefix: "basis")).to be true
    end

    it "blocks repeated calls in the same phased bucket" do
      limiter.due?(key: "BTC-USD:BIT-31JUL26-CDE", interval_seconds: 60, cache_prefix: "basis")

      expect(limiter.due?(key: "BTC-USD:BIT-31JUL26-CDE", interval_seconds: 60, cache_prefix: "basis")).to be false
    end

    it "allows the next call after the phased bucket advances" do
      limiter.due?(key: "BTC-USD:BIT-31JUL26-CDE", interval_seconds: 60, cache_prefix: "basis")

      travel_to Time.utc(2026, 6, 8, 17, 1, 5) do
        advanced_limiter = described_class.new(cache: cache)

        expect(advanced_limiter.due?(key: "BTC-USD:BIT-31JUL26-CDE", interval_seconds: 60, cache_prefix: "basis")).to be true
      end
    end

    it "assigns different phases across keys using Euclidean division" do
      phases = [
        "BTC-USD:BIT-31JUL26-CDE",
        "BTC-USD:BIT-28AUG26-CDE",
        "ETH-USD:ET-31JUL26-CDE"
      ].map { |key| limiter.phase_for(key, 60) }

      expect(phases.uniq.size).to be > 1
      expect(phases).to all(be_between(0, 59))
    end
  end

  describe ".gcd_interval" do
    it "returns the greatest common divisor for shared scheduling grids" do
      expect(described_class.gcd_interval(60, 30, 45)).to eq(15)
    end
  end
end
