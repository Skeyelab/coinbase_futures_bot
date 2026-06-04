# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::Components::StatusBar do
  let(:data) { {day_pos_count: 2, swing_pos_count: 1, signal_count: 3, halt_active: false, last_eval_at: nil} }

  subject(:bar) { described_class.new(data) }

  describe "#render" do
    it "includes ACTIVE when not halted" do
      expect(bar.render).to include("ACTIVE")
    end

    it "includes position counts" do
      expect(bar.render).to include("Day: 2").and include("Swing: 1")
    end

    it "includes signal count" do
      expect(bar.render).to include("Signals: 3")
    end

    it "shows never when no eval" do
      expect(bar.render).to include("never")
    end

    it "shows age when eval present" do
      data[:last_eval_at] = 30.seconds.ago
      expect(bar.render).to include("ago")
    end

    context "when halted" do
      let(:data) { {day_pos_count: 0, swing_pos_count: 0, signal_count: 0, halt_active: true, last_eval_at: nil} }

      it "includes HALTED" do
        expect(bar.render).to include("HALTED")
      end
    end
  end
end

RSpec.describe Tui::Components::PositionsTable do
  subject(:table) { described_class.new([], {}) }

  describe "#render" do
    it "includes section header" do
      expect(table.render).to include("Open Positions")
    end

    it "shows count" do
      expect(table.render).to include("(0)")
    end

    context "with positions" do
      let(:position) { create(:position, product_id: "BIT-26JUN26-CDE", side: "LONG", entry_price: 65000, size: 1) }

      subject(:table) { described_class.new([position], {}) }

      it "includes product id" do
        expect(table.render).to include("BIT-26JUN26-CDE")
      end
    end
  end
end

RSpec.describe Tui::Components::SignalsTable do
  subject(:table) { described_class.new([]) }

  describe "#render" do
    it "includes section header" do
      expect(table.render).to include("Active Signals")
    end

    context "with signals" do
      let(:signal) { create(:signal_alert, symbol: "BTC-USD", side: "long", confidence: 85) }

      subject(:table) { described_class.new([signal]) }

      it "includes symbol" do
        expect(table.render).to include("BTC-USD")
      end

      it "includes confidence" do
        expect(table.render).to include("85")
      end
    end
  end
end

RSpec.describe Tui::Components::PricesPanel do
  subject(:panel) { described_class.new([], []) }

  describe "#render" do
    it "includes futures section" do
      expect(panel.render).to include("Futures Prices")
    end

    it "includes spot section" do
      expect(panel.render).to include("Spot Prices")
    end

    context "with ticks" do
      let(:tick) { create(:tick, product_id: "BIT-26JUN26-CDE", price: 65000, observed_at: 5.seconds.ago) }

      subject(:panel) { described_class.new([tick], []) }

      it "includes product id" do
        expect(panel.render).to include("BIT-26JUN26-CDE")
      end

      it "marks live price" do
        expect(panel.render).to include("live")
      end
    end
  end
end
