# frozen_string_literal: true

require "rails_helper"

RSpec.describe SideNormalizer do
  describe ".position" do
    it "normalizes long/buy to LONG" do
      expect(described_class.position("long")).to eq("LONG")
      expect(described_class.position("buy")).to eq("LONG")
    end

    it "normalizes short/sell to SHORT" do
      expect(described_class.position("short")).to eq("SHORT")
      expect(described_class.position("sell")).to eq("SHORT")
    end

    it "returns nil for unknown values" do
      expect(described_class.position("sideways")).to be_nil
    end
  end

  describe ".signal" do
    it "normalizes long/buy to long" do
      expect(described_class.signal("long")).to eq("long")
      expect(described_class.signal("buy")).to eq("long")
    end

    it "normalizes short/sell to short" do
      expect(described_class.signal("short")).to eq("short")
      expect(described_class.signal("sell")).to eq("short")
    end
  end

  describe ".order" do
    it "normalizes supported order sides" do
      expect(described_class.order("long")).to eq("LONG")
      expect(described_class.order("buy")).to eq("BUY")
      expect(described_class.order("short")).to eq("SHORT")
      expect(described_class.order("sell")).to eq("SELL")
    end
  end

  describe ".order_symbol" do
    it "normalizes exchange sides to symbols" do
      expect(described_class.order_symbol("LONG")).to eq(:long)
      expect(described_class.order_symbol("SHORT")).to eq(:short)
      expect(described_class.order_symbol("BUY")).to eq(:buy)
      expect(described_class.order_symbol("SELL")).to eq(:sell)
    end

    it "returns nil for unknown values" do
      expect(described_class.order_symbol("WAIT")).to be_nil
    end
  end
end
