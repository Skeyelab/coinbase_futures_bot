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

  # Sizing keyed only by base currency cannot tell a $659 BTC PERP from a $100
  # dated BTC nano: Contract::PREFIX_TO_BASE_CURRENCY maps both BIT and BIP to
  # "BTC", so BIP inherited the nano's 5-contract / 2-concurrent shape.
  describe ".for_product" do
    it "gives BIP its own pinned sizing rather than the dated BTC nano's" do
      params = described_class.for_product("BIP-20DEC30-CDE")

      expect(params.max_contracts).to eq(1)
      expect(params.max_concurrent).to eq(1)
      expect(params.contract_size_usd).to be_within(1.0).of(659.0)
    end

    it "still resolves the dated BTC nano to the BTC asset entry" do
      params = described_class.for_product("BIT-31JUL26-CDE")

      expect(params.max_contracts).to eq(5)
      expect(params.max_concurrent).to eq(2)
      expect(params.contract_size_usd).to eq(100.0)
    end

    it "resolves a prefix with no contract entry through its base currency (NOL -> OIL)" do
      params = described_class.for_product("NOL-19AUG26-CDE")

      expect(params.max_contracts).to eq(1)
      expect(params.contract_size_usd).to eq(930.0)
    end

    it "falls back to the conservative default for an unrecognised product" do
      params = described_class.for_product("ZZZ-01JAN30-CDE")

      expect(params.max_contracts).to eq(2)
      expect(params.max_concurrent).to eq(1)
      expect(params.contract_size_usd).to eq(100.0)
    end

    it "falls back to the conservative default for a blank product id" do
      expect(described_class.for_product(nil).max_contracts).to eq(2)
    end

    # A contract entry overrides key-by-key, so a partial entry keeps the
    # asset's other knobs rather than silently reverting them to `default`.
    it "layers a partial contract entry over the asset entry" do
      sizing = described_class.new(
        "default" => {"contract_size_usd" => 100.0, "max_contracts" => 2, "max_concurrent" => 1},
        "assets" => {"BTC" => {"contract_size_usd" => 100.0, "max_contracts" => 5, "max_concurrent" => 2}},
        "contracts" => {"BIP" => {"max_contracts" => 1}}
      )

      params = sizing.for_product("BIP-20DEC30-CDE")
      expect(params.max_contracts).to eq(1)
      expect(params.max_concurrent).to eq(2)
      expect(params.contract_size_usd).to eq(100.0)
    end
  end
end
