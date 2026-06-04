# frozen_string_literal: true

require "rails_helper"

RSpec.describe Underlying, type: :model do
  describe "validations" do
    it "requires symbol" do
      u = Underlying.new(name: "Bitcoin", asset_class: "crypto")
      expect(u).not_to be_valid
      expect(u.errors[:symbol]).to be_present
    end

    it "requires unique symbol" do
      Underlying.create!(symbol: "BTC", name: "Bitcoin", asset_class: "crypto")
      dup = Underlying.new(symbol: "BTC", name: "Bitcoin", asset_class: "crypto")
      expect(dup).not_to be_valid
    end

    it "requires asset_class" do
      u = Underlying.new(symbol: "BTC", name: "Bitcoin")
      expect(u).not_to be_valid
      expect(u.errors[:asset_class]).to be_present
    end

    it "validates asset_class inclusion" do
      u = Underlying.new(symbol: "BTC", name: "Bitcoin", asset_class: "magic")
      expect(u).not_to be_valid
    end
  end

  describe "associations" do
    it "has many contracts" do
      u = Underlying.create!(symbol: "BTC", name: "Bitcoin", asset_class: "crypto")
      c = Contract.create!(product_id: "BIT-29AUG25-CDE", base_currency: "BTC", quote_currency: "USD", underlying: u)
      expect(u.contracts).to include(c)
    end
  end

  describe ".crypto" do
    it "returns only crypto underlyings" do
      Underlying.create!(symbol: "BTC", name: "Bitcoin", asset_class: "crypto")
      Underlying.create!(symbol: "OIL", name: "Crude Oil", asset_class: "commodity")
      expect(Underlying.crypto.pluck(:symbol)).to contain_exactly("BTC")
    end
  end

  describe ".commodity" do
    it "returns only commodity underlyings" do
      Underlying.create!(symbol: "BTC", name: "Bitcoin", asset_class: "crypto")
      Underlying.create!(symbol: "OIL", name: "Crude Oil", asset_class: "commodity")
      expect(Underlying.commodity.pluck(:symbol)).to contain_exactly("OIL")
    end
  end
end
