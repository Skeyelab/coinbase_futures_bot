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

    context "sentiment summary" do
      def snapshot(symbols:, stale: false)
        Sentiment::Snapshot::Result.new(symbols, Time.now, Time.now, [], stale)
      end

      def sym(name, z, count, window = "15m")
        Sentiment::Snapshot::SymbolSnapshot.new(name, z, count, window, Time.now)
      end

      it "shows a one-liner for symbols that have data" do
        data[:sentiment] = snapshot(symbols: [sym("OIL-USD", -0.4, 3)])

        expect(bar.render).to include("OIL-USD").and include("z=-0.4").and include("3/15m")
      end

      it "flags stale sentiment" do
        data[:sentiment] = snapshot(symbols: [sym("OIL-USD", -0.4, 3)], stale: true)

        expect(bar.render).to match(/stale/i)
      end

      it "renders without sentiment data present" do
        expect { bar.render }.not_to raise_error
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

      it "shows unset targets as em dash" do
        expect(table.render).to include("—")
      end
    end

    context "with take-profit and stop-loss targets" do
      let(:position) do
        create(:position, :with_tp_sl, product_id: "NOL-19JUN26-CDE", entry_price: 91.62)
      end

      subject(:table) { described_class.new([position], {}) }

      it "shows formatted take-profit and stop-loss" do
        rendered = table.render
        expect(rendered).to include("51000.00")
        expect(rendered).to include("49000.00")
      end
    end

    context "with trailing stop enabled" do
      let(:position) do
        create(:position, stop_loss: 88.5, trailing_stop_enabled: true, entry_price: 91.62)
      end

      subject(:table) { described_class.new([position], {}) }

      it "marks stop-loss with trailing badge" do
        expect(table.render).to include("88.50T")
      end
    end

    context "when stored pnl is zero but a live price is available" do
      let(:position) do
        create(:position,
          product_id: "NOL-19JUN26-CDE",
          side: "SHORT",
          entry_price: 93.62,
          size: 1,
          pnl: 0.0)
      end
      let(:live_prices) do
        {position.product_id => build(:tick, product_id: position.product_id, price: 93.41)}
      end

      subject(:table) { described_class.new([position], live_prices) }

      before do
        allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
      end

      it "shows live unrealized pnl instead of frozen zero" do
        expect(table.render).to include("+2.10")
      end
    end

    context "when no live price is available" do
      let(:position) { create(:position, pnl: 1.3) }

      subject(:table) { described_class.new([position], {}) }

      it "shows stored unrealized pnl from the exchange sync" do
        expect(table.render).to include("+1.30")
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
