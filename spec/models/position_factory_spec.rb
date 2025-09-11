# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Position factory", type: :factory do
  describe "default position" do
    it "creates a valid day trading position by default" do
      position = create(:position)
      expect(position).to be_valid
      expect(position.day_trading).to be true
      expect(position.status).to eq("OPEN")
    end
  end

  describe ":swing_trading trait" do
    it "creates a swing trading position" do
      position = create(:position, :swing_trading)
      expect(position).to be_valid
      expect(position.day_trading).to be false
      expect(position.status).to eq("OPEN")
    end
  end

  describe ":multi_day trait" do
    it "creates a multi-day swing trading position" do
      position = create(:position, :multi_day)
      expect(position).to be_valid
      expect(position.day_trading).to be false
      expect(position.status).to eq("OPEN")
      expect(position.entry_time).to be < 2.days.ago
    end
  end

  describe "combining traits" do
    it "allows combining swing_trading with other traits" do
      position = create(:position, :swing_trading, :short, :eth)
      expect(position).to be_valid
      expect(position.day_trading).to be false
      expect(position.side).to eq("SHORT")
      expect(position.product_id).to eq("ET-29AUG25-CDE")
    end
  end
end
