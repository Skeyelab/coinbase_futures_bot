# frozen_string_literal: true

require "rails_helper"

RSpec.describe FuturesContract, type: :service do
  describe ".parse_expiry_date" do
    context "with valid Coinbase futures product IDs" do
      it "parses BIT product IDs correctly" do
        expect(FuturesContract.parse_expiry_date("BIT-29AUG25-CDE")).to eq(Date.new(2025, 8, 29))
        expect(FuturesContract.parse_expiry_date("BIT-15SEP25-CDE")).to eq(Date.new(2025, 9, 15))
        expect(FuturesContract.parse_expiry_date("BIT-31DEC24-CDE")).to eq(Date.new(2024, 12, 31))
      end

      it "parses ET product IDs correctly" do
        expect(FuturesContract.parse_expiry_date("ET-29AUG25-CDE")).to eq(Date.new(2025, 8, 29))
        expect(FuturesContract.parse_expiry_date("ET-15SEP25-CDE")).to eq(Date.new(2025, 9, 15))
        expect(FuturesContract.parse_expiry_date("ET-31DEC24-CDE")).to eq(Date.new(2024, 12, 31))
      end

      it "handles single digit days" do
        expect(FuturesContract.parse_expiry_date("BIT-1JAN25-CDE")).to eq(Date.new(2025, 1, 1))
        expect(FuturesContract.parse_expiry_date("ET-5FEB25-CDE")).to eq(Date.new(2025, 2, 5))
      end

      it "handles all month abbreviations" do
        expect(FuturesContract.parse_expiry_date("BIT-15JAN25-CDE")).to eq(Date.new(2025, 1, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15FEB25-CDE")).to eq(Date.new(2025, 2, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15MAR25-CDE")).to eq(Date.new(2025, 3, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15APR25-CDE")).to eq(Date.new(2025, 4, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15MAY25-CDE")).to eq(Date.new(2025, 5, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15JUN25-CDE")).to eq(Date.new(2025, 6, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15JUL25-CDE")).to eq(Date.new(2025, 7, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15AUG25-CDE")).to eq(Date.new(2025, 8, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15SEP25-CDE")).to eq(Date.new(2025, 9, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15OCT25-CDE")).to eq(Date.new(2025, 10, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15NOV25-CDE")).to eq(Date.new(2025, 11, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15DEC25-CDE")).to eq(Date.new(2025, 12, 15))
      end

      it "handles 2-digit years correctly" do
        # Years 00-69 should be 2000-2069
        expect(FuturesContract.parse_expiry_date("BIT-15JAN00-CDE")).to eq(Date.new(2000, 1, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15JAN30-CDE")).to eq(Date.new(2030, 1, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15JAN69-CDE")).to eq(Date.new(2069, 1, 15))

        # Years 70-99 should be 1970-1999
        expect(FuturesContract.parse_expiry_date("BIT-15JAN70-CDE")).to eq(Date.new(1970, 1, 15))
        expect(FuturesContract.parse_expiry_date("BIT-15JAN99-CDE")).to eq(Date.new(1999, 1, 15))
      end
    end

    context "with invalid product IDs" do
      it "returns nil for non-string inputs" do
        expect(FuturesContract.parse_expiry_date(nil)).to be_nil
        expect(FuturesContract.parse_expiry_date(123)).to be_nil
        expect(FuturesContract.parse_expiry_date([])).to be_nil
      end

      it "returns nil for invalid format" do
        expect(FuturesContract.parse_expiry_date("BTC-USD")).to be_nil
        expect(FuturesContract.parse_expiry_date("INVALID-FORMAT")).to be_nil
        expect(FuturesContract.parse_expiry_date("BIT-INVALID-CDE")).to be_nil
      end

      it "returns nil for invalid dates" do
        expect(FuturesContract.parse_expiry_date("BIT-31FEB25-CDE")).to be_nil # Feb 31st doesn't exist
        expect(FuturesContract.parse_expiry_date("BIT-32JAN25-CDE")).to be_nil # Jan 32nd doesn't exist
      end

      it "returns nil for invalid month abbreviations" do
        expect(FuturesContract.parse_expiry_date("BIT-15XXX25-CDE")).to be_nil
        expect(FuturesContract.parse_expiry_date("BIT-15INVALID25-CDE")).to be_nil
      end
    end
  end

  describe ".days_until_expiry" do
    before do
      travel_to Date.new(2025, 8, 25) # Monday, August 25, 2025
    end

    after do
      travel_back
    end

    it "calculates days correctly for future dates" do
      expect(FuturesContract.days_until_expiry("BIT-29AUG25-CDE")).to eq(4) # Aug 29 is 4 days away
      expect(FuturesContract.days_until_expiry("BIT-15SEP25-CDE")).to eq(21) # Sep 15 is 21 days away
    end

    it "returns 0 for today" do
      expect(FuturesContract.days_until_expiry("BIT-25AUG25-CDE")).to eq(0)
    end

    it "returns negative for past dates" do
      expect(FuturesContract.days_until_expiry("BIT-20AUG25-CDE")).to eq(-5) # 5 days ago
    end

    it "returns nil for unparseable product IDs" do
      expect(FuturesContract.days_until_expiry("INVALID-FORMAT")).to be_nil
      expect(FuturesContract.days_until_expiry(nil)).to be_nil
    end
  end

  describe ".parse_expiry_from_api" do
    it "uses API expiration_time when available" do
      api_response = {
        "product_id" => "BIT-29AUG25-CDE",
        "expiration_time" => "2025-08-29T16:00:00Z"
      }

      expect(FuturesContract.parse_expiry_from_api(api_response)).to eq(Date.new(2025, 8, 29))
    end

    it "falls back to product ID parsing when API time is invalid" do
      api_response = {
        "product_id" => "BIT-29AUG25-CDE",
        "expiration_time" => "invalid-time"
      }

      expect(FuturesContract.parse_expiry_from_api(api_response)).to eq(Date.new(2025, 8, 29))
    end

    it "falls back to product ID parsing when no API time" do
      api_response = {
        "product_id" => "BIT-29AUG25-CDE"
      }

      expect(FuturesContract.parse_expiry_from_api(api_response)).to eq(Date.new(2025, 8, 29))
    end

    it "handles missing product_id gracefully" do
      api_response = {
        "expiration_time" => "2025-08-29T16:00:00Z"
      }

      expect(FuturesContract.parse_expiry_from_api(api_response)).to eq(Date.new(2025, 8, 29))
    end

    it "returns nil when both expiration_time and product_id are missing" do
      api_response = {}

      expect(FuturesContract.parse_expiry_from_api(api_response)).to be_nil
    end
  end

  describe ".get_expiry_info" do
    let(:positions_service) { double("positions_service") }
    let(:product_id) { "BIT-29AUG25-CDE" }

    it "returns basic info without positions service" do
      result = FuturesContract.get_expiry_info(product_id)

      expect(result[:product_id]).to eq(product_id)
      expect(result[:parsed_date]).to eq(Date.new(2025, 8, 29))
      expect(result[:api_expiry_time]).to be_nil
      expect(result[:api_days_until_expiry]).to be_nil
    end

    it "fetches API data when positions service provided" do
      api_response = [{
        "product_id" => product_id,
        "expiration_time" => "2025-08-29T16:00:00Z"
      }]

      allow(positions_service).to receive(:list_open_positions).with(product_id: product_id).and_return(api_response)

      result = FuturesContract.get_expiry_info(product_id, positions_service: positions_service)

      expect(result[:api_expiry_time]).to eq("2025-08-29T16:00:00Z")
    end

    it "handles API errors gracefully" do
      allow(positions_service).to receive(:list_open_positions).and_raise(StandardError, "API error")

      result = FuturesContract.get_expiry_info(product_id, positions_service: positions_service)

      expect(result[:api_expiry_time]).to be_nil
      expect(result[:parsed_date]).to eq(Date.new(2025, 8, 29))
    end
  end

  describe ".expiring_soon?" do
    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "returns true for contracts expiring within buffer" do
      expect(FuturesContract.expiring_soon?("BIT-27AUG25-CDE", 2)).to be true # 2 days away
      expect(FuturesContract.expiring_soon?("BIT-26AUG25-CDE", 2)).to be true # 1 day away
      expect(FuturesContract.expiring_soon?("BIT-25AUG25-CDE", 2)).to be true # today
    end

    it "returns false for contracts expiring beyond buffer" do
      expect(FuturesContract.expiring_soon?("BIT-28AUG25-CDE", 2)).to be false # 3 days away
      expect(FuturesContract.expiring_soon?("BIT-30AUG25-CDE", 2)).to be false # 5 days away
    end

    it "returns false for unparseable contracts" do
      expect(FuturesContract.expiring_soon?("INVALID-FORMAT", 2)).to be false
    end
  end

  describe ".expired?" do
    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "returns true for expired contracts" do
      expect(FuturesContract.expired?("BIT-24AUG25-CDE")).to be true # yesterday
      expect(FuturesContract.expired?("BIT-20AUG25-CDE")).to be true # 5 days ago
    end

    it "returns false for future contracts" do
      expect(FuturesContract.expired?("BIT-25AUG25-CDE")).to be false # today
      expect(FuturesContract.expired?("BIT-26AUG25-CDE")).to be false # tomorrow
    end

    it "returns false for unparseable contracts" do
      expect(FuturesContract.expired?("INVALID-FORMAT")).to be false
    end
  end

  describe ".find_expiring_positions" do
    let!(:expiring_position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-30AUG25-CDE", status: "OPEN") }
    let!(:closed_position) { create(:position, product_id: "BIT-26AUG25-CDE", status: "CLOSED") }

    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "returns only open positions expiring within buffer" do
      result = FuturesContract.find_expiring_positions(2)

      expect(result).to include(expiring_position)
      expect(result).not_to include(safe_position)
      expect(result).not_to include(closed_position)
    end

    it "returns empty array when no expiring positions" do
      result = FuturesContract.find_expiring_positions(0)
      expect(result).to be_empty
    end
  end

  describe ".find_expired_positions" do
    let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }
    let!(:current_position) { create(:position, product_id: "BIT-26AUG25-CDE", status: "OPEN") }

    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "returns only expired positions" do
      result = FuturesContract.find_expired_positions

      expect(result).to include(expired_position)
      expect(result).not_to include(current_position)
    end
  end

  describe ".margin_impact_near_expiry" do
    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "returns correct multipliers based on days until expiry" do
      # Expiry within 24 hours
      result = FuturesContract.margin_impact_near_expiry("BIT-25AUG25-CDE") # today
      expect(result[:multiplier]).to eq(2.0)
      expect(result[:reason]).to include("double margin")

      # Expiry within 3 days
      result = FuturesContract.margin_impact_near_expiry("BIT-27AUG25-CDE") # 2 days
      expect(result[:multiplier]).to eq(1.5)
      expect(result[:reason]).to include("50% higher")

      # Expiry within 1 week
      result = FuturesContract.margin_impact_near_expiry("BIT-29AUG25-CDE") # 4 days
      expect(result[:multiplier]).to eq(1.2)
      expect(result[:reason]).to include("20% higher")

      # Normal margin
      result = FuturesContract.margin_impact_near_expiry("BIT-05SEP25-CDE") # 11 days
      expect(result[:multiplier]).to eq(1.0)
      expect(result[:reason]).to include("Normal margin")
    end

    it "returns nil for unparseable contracts" do
      expect(FuturesContract.margin_impact_near_expiry("INVALID-FORMAT")).to be_nil
    end
  end

  describe ".format_expiry_summary" do
    let(:positions) do
      [
        double("position1", product_id: "BIT-25AUG25-CDE"), # today
        double("position2", product_id: "BIT-26AUG25-CDE"), # tomorrow
        double("position3", product_id: "BIT-27AUG25-CDE"), # 2 days
        double("position4", product_id: "INVALID-FORMAT")   # unknown
      ]
    end

    before do
      travel_to Date.new(2025, 8, 25)
    end

    after do
      travel_back
    end

    it "formats summary correctly" do
      summary = FuturesContract.format_expiry_summary(positions)

      expect(summary).to include("expiring TODAY")
      expect(summary).to include("expiring TOMORROW")
      expect(summary).to include("expiring in 2 days")
      expect(summary).to include("unknown expiry")
    end

    it "returns message for empty positions" do
      summary = FuturesContract.format_expiry_summary([])
      expect(summary).to eq("No positions to summarize")
    end
  end
end
