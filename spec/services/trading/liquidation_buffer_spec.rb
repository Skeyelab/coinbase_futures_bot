# frozen_string_literal: true

require "rails_helper"

# Issue #399 (ADR 0003): exit a leveraged position BEFORE it reaches liquidation.
# Pure math (table-tested like CostModel): isolated-margin liquidation price from
# entry/side/leverage/maintenance-margin, then a buffered exit that sits `buffer`
# of the entry→liq distance on the safe side of the liq price.
#
# With leverage 10 (initial margin 0.1), maintenance_margin_rate 0.005:
#   loss-to-liq fraction = im - mm = 0.095
#   long  entry 100 -> liq 90.5  ; buffered = 90.5 + 0.05*9.5 = 90.975
#   short entry 100 -> liq 109.5 ; buffered = 109.5 - 0.05*9.5 = 109.025
RSpec.describe Trading::LiquidationBuffer, type: :service do
  subject(:calc) { described_class.new(buffer: 0.05, maintenance_margin_rate: 0.005) }

  describe "#liquidation_price" do
    it "is below entry for a long, above entry for a short" do
      expect(calc.liquidation_price(entry_price: 100.0, side: "long", leverage: 10)).to be_within(1e-9).of(90.5)
      expect(calc.liquidation_price(entry_price: 100.0, side: "short", leverage: 10)).to be_within(1e-9).of(109.5)
    end

    it "moves closer to entry as leverage rises" do
      liq5 = calc.liquidation_price(entry_price: 100.0, side: "long", leverage: 5)   # im 0.2 -> 80.5
      liq20 = calc.liquidation_price(entry_price: 100.0, side: "long", leverage: 20) # im 0.05 -> 95.5
      expect(liq5).to be_within(1e-9).of(80.5)
      expect(liq20).to be_within(1e-9).of(95.5)
    end
  end

  describe "#buffered_exit_price (safe side of liq)" do
    it "sits above liq for a long, below liq for a short" do
      expect(calc.buffered_exit_price(entry_price: 100.0, side: "long", leverage: 10)).to be_within(1e-9).of(90.975)
      expect(calc.buffered_exit_price(entry_price: 100.0, side: "short", leverage: 10)).to be_within(1e-9).of(109.025)
    end
  end

  describe "#breached?" do
    it "is true once a long falls to/through the buffered price" do
      expect(calc.breached?(entry_price: 100.0, side: "long", leverage: 10, current_price: 91.0)).to be false
      expect(calc.breached?(entry_price: 100.0, side: "long", leverage: 10, current_price: 90.975)).to be true
      expect(calc.breached?(entry_price: 100.0, side: "long", leverage: 10, current_price: 90.0)).to be true
    end

    it "is true once a short rises to/through the buffered price" do
      expect(calc.breached?(entry_price: 100.0, side: "short", leverage: 10, current_price: 109.0)).to be false
      expect(calc.breached?(entry_price: 100.0, side: "short", leverage: 10, current_price: 109.025)).to be true
      expect(calc.breached?(entry_price: 100.0, side: "short", leverage: 10, current_price: 110.0)).to be true
    end

    it "is false with missing/nonsense inputs (never a spurious close)" do
      expect(calc.breached?(entry_price: nil, side: "long", leverage: 10, current_price: 1.0)).to be false
      expect(calc.breached?(entry_price: 100.0, side: "long", leverage: 0, current_price: 1.0)).to be false
      expect(calc.breached?(entry_price: 100.0, side: "long", leverage: 10, current_price: nil)).to be false
    end
  end

  describe "#enabled?" do
    it "needs a positive buffer and leverage to be active" do
      expect(described_class.new(buffer: 0.05).enabled?).to be true
      expect(described_class.new(buffer: 0.0).enabled?).to be false
      expect(described_class.new(buffer: nil).enabled?).to be false
    end
  end
end
