# frozen_string_literal: true

require "rails_helper"

# Declarative per-symbol strategy selection (issue #303): a YAML map of
# symbol -> strategy + frozen params. Any symbol without an ENABLED entry
# resolves to the default MultiTimeframeSignal — the file is zero behavior
# change until an operator flips an entry on.
RSpec.describe Trading::StrategySelection, type: :service do
  def selection(data)
    described_class.new(data)
  end

  let(:data) do
    {
      "default" => {"strategy" => "MultiTimeframeSignal"},
      "symbols" => {
        "BIP-TEST-CDE" => {
          "strategy" => "FundingSkewContrarian",
          "enabled" => true,
          "min_confidence" => 0,
          "params" => {
            "entry_z" => 2.0, "exit_z" => 0.5, "window" => 168,
            "stop" => 0.01, "spot_symbol" => "BTC-USD"
          }
        }
      }
    }
  end

  describe "#for_symbol" do
    it "defaults to MultiTimeframeSignal for an unconfigured symbol" do
      sel = selection(data).for_symbol("ETH-PERP-CDE")

      expect(sel.strategy_name).to eq("MultiTimeframeSignal")
      expect(sel.params).to eq({})
      expect(sel.min_confidence).to be_nil
      expect(sel.configured?).to be(false)
    end

    it "returns the configured strategy with symbolized params for an enabled entry" do
      sel = selection(data).for_symbol("BIP-TEST-CDE")

      expect(sel.strategy_name).to eq("FundingSkewContrarian")
      expect(sel.configured?).to be(true)
      expect(sel.params).to eq(entry_z: 2.0, exit_z: 0.5, window: 168,
        stop: 0.01, spot_symbol: "BTC-USD")
      expect(sel.min_confidence).to eq(0.0)
    end

    it "falls back to the default while the entry is disabled (the operator switch)" do
      data["symbols"]["BIP-TEST-CDE"]["enabled"] = false

      sel = selection(data).for_symbol("BIP-TEST-CDE")

      expect(sel.strategy_name).to eq("MultiTimeframeSignal")
      expect(sel.configured?).to be(false)
    end

    it "treats an entry without an enabled key as enabled" do
      data["symbols"]["BIP-TEST-CDE"].delete("enabled")

      expect(selection(data).for_symbol("BIP-TEST-CDE").configured?).to be(true)
    end

    it "leaves min_confidence nil when the entry does not set one" do
      data["symbols"]["BIP-TEST-CDE"].delete("min_confidence")

      expect(selection(data).for_symbol("BIP-TEST-CDE").min_confidence).to be_nil
    end

    it "survives an empty or nil config" do
      expect(selection(nil).for_symbol("X-CDE").strategy_name).to eq("MultiTimeframeSignal")
      expect(selection({}).for_symbol("X-CDE").configured?).to be(false)
    end
  end

  describe "#entries" do
    it "lists enabled entries only, by default" do
      data["symbols"]["XPP-TEST-CDE"] = {"strategy" => "FundingSkewContrarian", "enabled" => false}

      symbols = selection(data).entries.map(&:symbol)

      expect(symbols).to eq(["BIP-TEST-CDE"])
    end

    it "includes disabled entries when asked (pre-flip validation)" do
      data["symbols"]["XPP-TEST-CDE"] = {"strategy" => "FundingSkewContrarian", "enabled" => false}

      symbols = selection(data).entries(include_disabled: true).map(&:symbol)

      expect(symbols).to contain_exactly("BIP-TEST-CDE", "XPP-TEST-CDE")
    end
  end

  describe "#fingerprint" do
    it "is stable for identical data and changes when the config changes" do
      a = selection(data).fingerprint
      b = selection(Marshal.load(Marshal.dump(data))).fingerprint
      data["symbols"]["BIP-TEST-CDE"]["params"]["entry_z"] = 2.5
      c = selection(data).fingerprint

      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end
  end

  describe "the shipped config/strategy_selection.yml" do
    # The gate-passing frozen set from #568. A change here mid-sample voids the
    # #376 gate-2a evidence window — this spec is part of the freeze.
    it "declares the funding-skew pairing for BIP with the gate-passing params" do
      entry = described_class.default.entries(include_disabled: true)
        .find { |s| s.symbol == "BIP-20DEC30-CDE" }

      expect(entry).not_to be_nil
      expect(entry.strategy_name).to eq("FundingSkewContrarian")
      expect(entry.params).to include(entry_z: 2.0, exit_z: 0.5, window: 168,
        stop: 0.01, spot_symbol: "BTC-USD")
      expect(entry.min_confidence).to eq(0.0)
    end

    it "ships with the BIP entry DISABLED — the flip is explicit and operator-owned" do
      expect(described_class.default.for_symbol("BIP-20DEC30-CDE").configured?).to be(false)
    end
  end
end
