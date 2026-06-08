# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::Layout do
  subject(:layout) { described_class.new(active_tab: :overview, width: 100) }

  describe "#switch_to" do
    it "switches tab by number key" do
      expect(layout.switch_to(3).active_tab).to eq(:signals)
    end

    it "ignores invalid tab numbers" do
      expect(layout.switch_to(9).active_tab).to eq(:overview)
    end
  end

  describe "#switch_to_tab" do
    it "switches by symbol" do
      expect(layout.switch_to_tab(:health).active_tab).to eq(:health)
    end
  end

  describe "#tab_number" do
    it "returns 1-based index" do
      expect(layout.tab_number).to eq(1)
      expect(layout.switch_to_tab(:market).tab_number).to eq(4)
    end
  end
end

RSpec.describe Tui::Components::TabBar do
  let(:layout) { Tui::Layout.new(active_tab: :signals) }

  subject(:bar) { described_class.new(layout) }

  describe "#render" do
    it "renders all five tabs" do
      expect(bar.render).to include("Overview").and include("Ops")
    end

    it "includes tab number hints" do
      expect(bar.render).to include("1 Overview").and include("3 Signals")
    end
  end
end

RSpec.describe Tui::Components::PanelFrame do
  subject(:frame) { described_class.new(title: "Positions", count: 2, width: 40) }

  describe "#render" do
    it "includes title and count" do
      output = frame.render("table body")
      expect(output).to include("Positions").and include("(2)")
    end

    it "wraps content" do
      expect(frame.render("hello")).to include("hello")
    end
  end
end
