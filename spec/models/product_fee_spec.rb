# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductFee do
  def measure!(product, per_contract, samples: 10, liquidity: "TAKER")
    described_class.create!(product_id: product, liquidity: liquidity,
      commission_per_contract: per_contract, sample_size: samples, measured_at: Time.current)
  end

  describe ".measured_per_contract" do
    it "returns the measured commission for a product" do
      measure!("NOL-19AUG26-CDE", 0.85)

      expect(described_class.measured_per_contract("NOL-19AUG26-CDE")).to eq(0.85)
    end

    # nil must mean "fall back to the seeded constant", never "free".
    it "returns nil for a product that has never been measured" do
      expect(described_class.measured_per_contract("BIT-29AUG25-CDE")).to be_nil
    end

    # One atypical fill should not move what every live gate charges.
    it "ignores a measurement built from too few fills" do
      measure!("BIT-29AUG25-CDE", 12.34, samples: 1)

      expect(described_class.measured_per_contract("BIT-29AUG25-CDE")).to be_nil
    end

    it "keeps taker and maker measurements separate" do
      measure!("NOL-19AUG26-CDE", 0.85, liquidity: "TAKER")
      measure!("NOL-19AUG26-CDE", 0.10, liquidity: "MAKER")

      expect(described_class.measured_per_contract("NOL-19AUG26-CDE", liquidity: "TAKER")).to eq(0.85)
      expect(described_class.measured_per_contract("NOL-19AUG26-CDE", liquidity: "MAKER")).to eq(0.10)
    end
  end
end
