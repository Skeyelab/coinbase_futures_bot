# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::OperationsCatalog do
  describe ".entries" do
    it "lists the operator actions available from the dashboard" do
      keys = described_class.entries.map(&:key)

      expect(keys).to include("i", "c", "o", "h", "t", "s", "m", "r")
    end
  end

  describe ".for_tab" do
    it "returns all global operations on every tab" do
      keys = described_class.for_tab(:positions).map(&:key)

      expect(keys).to include("i", "c", "t", "s", "?")
    end

    it "includes realtime monitoring on the ops tab" do
      keys = described_class.for_tab(:health).map(&:key)

      expect(keys).to include("m")
    end
  end
end
