# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::AssetSizing do
  describe ".for" do
    it "returns the configured sizing for a known asset (ETH)" do
      params = described_class.for("ETH")
      expect(params.contract_size_usd).to eq(10.0)
      expect(params.max_contracts).to eq(10)
      expect(params.max_concurrent).to eq(3)
    end

    # OIL (NOL) has ~9x a BTC nano's per-contract notional, so it must NOT
    # inherit the crypto-shaped caps it used to hit via the `else` branch.
    it "caps OIL conservatively instead of crypto defaults" do
      params = described_class.for("OIL")
      expect(params.max_contracts).to eq(1)
      expect(params.max_concurrent).to eq(1)
      expect(params.contract_size_usd).to eq(930.0)
    end

    # An unlisted asset must fall to the conservative default, never the old
    # crypto-shaped `else` (max_contracts 5, max_concurrent 2).
    it "falls back to conservative defaults for an unknown asset" do
      params = described_class.for("DOGE")
      expect(params.max_contracts).to eq(2)
      expect(params.max_concurrent).to eq(1)
      expect(params.contract_size_usd).to eq(100.0)
    end

    it "accepts a symbol asset key" do
      expect(described_class.for(:BTC).max_contracts).to eq(5)
    end
  end
end
