# frozen_string_literal: true

require "rails_helper"

RSpec.describe Position, type: :model do
  before do
    travel_to Date.new(2025, 8, 25) # Monday, August 25, 2025
  end

  after do
    travel_back
  end

  describe "contract expiry scopes" do
    let!(:expiring_today) { create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN") }
    let!(:expiring_tomorrow) { create(:position, product_id: "BIT-26AUG25-CDE", status: "OPEN") }
    let!(:expiring_in_2_days) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-05SEP25-CDE", status: "OPEN") }
    let!(:closed_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "CLOSED") }
    let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }

    describe ".expiring_within_days" do
      it "returns positions expiring within specified days" do
        result = Position.expiring_within_days(2)

        expect(result).to include(expiring_today, expiring_tomorrow, expiring_in_2_days)
        expect(result).not_to include(safe_position, closed_position)
      end

      it "returns empty array when no positions expiring within days" do
        result = Position.expiring_within_days(0)
        expect(result).to contain_exactly(expiring_today)
      end
    end

    describe ".contract_expiring_soon" do
      it "returns positions expiring within buffer days (default 2)" do
        result = Position.contract_expiring_soon

        expect(result).to include(expiring_today, expiring_tomorrow, expiring_in_2_days)
        expect(result).not_to include(safe_position, closed_position)
      end

      it "accepts custom buffer days" do
        result = Position.contract_expiring_soon(1)

        expect(result).to include(expiring_today, expiring_tomorrow)
        expect(result).not_to include(expiring_in_2_days, safe_position)
      end
    end

    describe ".contract_expiring_today" do
      it "returns only positions expiring today" do
        result = Position.contract_expiring_today

        expect(result).to contain_exactly(expiring_today)
      end
    end

    describe ".contract_expired" do
      it "returns only expired positions" do
        result = Position.contract_expired

        expect(result).to contain_exactly(expired_position)
      end
    end
  end

  describe "contract expiry instance methods" do
    let(:position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }

    describe "#days_until_expiry" do
      it "delegates to FuturesContract.days_until_expiry" do
        expect(FuturesContract).to receive(:days_until_expiry).with("BIT-27AUG25-CDE").and_return(2)

        expect(position.days_until_expiry).to eq(2)
      end
    end

    describe "#expiring_soon?" do
      it "delegates to FuturesContract.expiring_soon?" do
        expect(FuturesContract).to receive(:expiring_soon?).with("BIT-27AUG25-CDE", 2).and_return(true)

        expect(position.expiring_soon?(2)).to be true
      end

      it "uses default buffer of 2 days" do
        expect(FuturesContract).to receive(:expiring_soon?).with("BIT-27AUG25-CDE", 2).and_return(true)

        expect(position.expiring_soon?).to be true
      end
    end

    describe "#expired?" do
      it "delegates to FuturesContract.expired?" do
        expect(FuturesContract).to receive(:expired?).with("BIT-27AUG25-CDE").and_return(false)

        expect(position.expired?).to be false
      end
    end

    describe "#expiry_date" do
      it "delegates to FuturesContract.parse_expiry_date" do
        expect(FuturesContract).to receive(:parse_expiry_date).with("BIT-27AUG25-CDE")
          .and_return(Date.new(2025, 8, 27))

        expect(position.expiry_date).to eq(Date.new(2025, 8, 27))
      end
    end

    describe "#needs_expiry_closure?" do
      context "when position is open and expiring soon" do
        before do
          allow(position).to receive(:open?).and_return(true)
          allow(position).to receive(:expiring_soon?).with(2).and_return(true)
        end

        it "returns true" do
          expect(position.needs_expiry_closure?(2)).to be true
        end
      end

      context "when position is closed" do
        before do
          allow(position).to receive(:open?).and_return(false)
          allow(position).to receive(:expiring_soon?).with(2).and_return(true)
        end

        it "returns false" do
          expect(position.needs_expiry_closure?(2)).to be false
        end
      end

      context "when position is not expiring soon" do
        before do
          allow(position).to receive(:open?).and_return(true)
          allow(position).to receive(:expiring_soon?).with(2).and_return(false)
        end

        it "returns false" do
          expect(position.needs_expiry_closure?(2)).to be false
        end
      end
    end

    describe "#margin_impact_near_expiry" do
      it "delegates to FuturesContract.margin_impact_near_expiry" do
        expected_impact = {multiplier: 1.2, reason: "Test reason"}
        expect(FuturesContract).to receive(:margin_impact_near_expiry).with("BIT-27AUG25-CDE")
          .and_return(expected_impact)

        expect(position.margin_impact_near_expiry).to eq(expected_impact)
      end
    end

    describe "#get_current_market_price" do
      context "when recent tick data is available" do
        let!(:recent_tick) { create(:tick, product_id: "BIT-27AUG25-CDE", price: 50000, observed_at: 2.minutes.ago) }

        it "returns tick price" do
          expect(position.get_current_market_price).to eq(50000)
        end
      end

      context "when recent candle data is available but no recent ticks" do
        let!(:old_tick) { create(:tick, product_id: "BIT-27AUG25-CDE", price: 49000, observed_at: 10.minutes.ago) }
        let!(:recent_candle) { create(:candle, symbol: "BIT-27AUG25-CDE", granularity: 60, close: 50500, timestamp: 3.minutes.ago) }

        it "returns candle close price" do
          expect(position.get_current_market_price).to eq(50500)
        end
      end

      context "when no recent data is available" do
        let!(:old_tick) { create(:tick, product_id: "BIT-27AUG25-CDE", price: 49000, observed_at: 10.minutes.ago) }
        let!(:old_candle) { create(:candle, symbol: "BIT-27AUG25-CDE", granularity: 60, close: 50500, timestamp: 10.minutes.ago) }

        it "returns nil and logs warning" do
          expect(Rails.logger).to receive(:warn).with(/No recent price data for BIT-27AUG25-CDE/)

          expect(position.get_current_market_price).to be_nil
        end
      end
    end
  end

  describe "contract expiry class methods" do
    let!(:expiring_position1) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
    let!(:expiring_position2) { create(:position, product_id: "BIT-26AUG25-CDE", status: "OPEN") }
    let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-05SEP25-CDE", status: "OPEN") }

    describe ".positions_approaching_expiry" do
      it "delegates to FuturesContract.find_expiring_positions" do
        expected_positions = [expiring_position1, expiring_position2]
        expect(FuturesContract).to receive(:find_expiring_positions).with(2).and_return(expected_positions)

        result = Position.positions_approaching_expiry(2)
        expect(result).to eq(expected_positions)
      end
    end

    describe ".positions_expiring_today" do
      it "calls find_expiring_positions with 0 days" do
        expected_positions = [expiring_position2] # Assuming it expires today
        expect(FuturesContract).to receive(:find_expiring_positions).with(0).and_return(expected_positions)

        result = Position.positions_expiring_today
        expect(result).to eq(expected_positions)
      end
    end

    describe ".expired_positions" do
      it "delegates to FuturesContract.find_expired_positions" do
        expected_positions = [expired_position]
        expect(FuturesContract).to receive(:find_expired_positions).and_return(expected_positions)

        result = Position.expired_positions
        expect(result).to eq(expected_positions)
      end
    end

    describe ".close_expiring_positions" do
      before do
        allow(Position).to receive(:positions_approaching_expiry).and_return([expiring_position1, expiring_position2])
        allow(expiring_position1).to receive(:get_current_market_price).and_return(50000)
        allow(expiring_position2).to receive(:get_current_market_price).and_return(51000)
        allow(expiring_position1).to receive(:force_close!)
        allow(expiring_position2).to receive(:force_close!)
      end

      it "closes all expiring positions with default parameters" do
        result = Position.close_expiring_positions

        expect(result).to eq(2)
        expect(expiring_position1).to have_received(:force_close!).with(50000, "Contract expiry")
        expect(expiring_position2).to have_received(:force_close!).with(51000, "Contract expiry")
      end

      it "accepts custom parameters" do
        Position.close_expiring_positions(3, 52000, "Custom reason")

        expect(Position).to have_received(:positions_approaching_expiry).with(3)
        expect(expiring_position1).to have_received(:force_close!).with(52000, "Custom reason")
        expect(expiring_position2).to have_received(:force_close!).with(52000, "Custom reason")
      end

      it "skips positions without current price" do
        allow(expiring_position1).to receive(:get_current_market_price).and_return(nil)

        result = Position.close_expiring_positions

        expect(result).to eq(1) # Only expiring_position2 closed
        expect(expiring_position1).not_to have_received(:force_close!)
        expect(expiring_position2).to have_received(:force_close!)
      end

      it "handles errors gracefully" do
        allow(expiring_position1).to receive(:force_close!).and_raise(StandardError, "Close error")
        expect(Rails.logger).to receive(:error).with(/Failed to close expiring position.*Close error/)

        result = Position.close_expiring_positions

        expect(result).to eq(1) # Only expiring_position2 closed successfully
      end

      it "returns 0 when no expiring positions" do
        allow(Position).to receive(:positions_approaching_expiry).and_return([])

        result = Position.close_expiring_positions
        expect(result).to eq(0)
      end

      it "logs closure activity" do
        expect(Rails.logger).to receive(:info).with(/Closed 2 positions approaching contract expiry/)

        Position.close_expiring_positions
      end
    end

    describe ".emergency_close_expired_positions" do
      before do
        allow(Position).to receive(:expired_positions).and_return([expired_position])
        allow(expired_position).to receive(:get_current_market_price).and_return(48000)
        allow(expired_position).to receive(:force_close!)
      end

      it "closes all expired positions" do
        result = Position.emergency_close_expired_positions

        expect(result).to eq(1)
        expect(expired_position).to have_received(:force_close!).with(48000, "EMERGENCY: Contract expired")
      end

      it "accepts custom close price" do
        Position.emergency_close_expired_positions(49000)

        expect(expired_position).to have_received(:force_close!).with(49000, "EMERGENCY: Contract expired")
      end

      it "logs emergency activity" do
        expect(Rails.logger).to receive(:error).with(/EMERGENCY: Found 1 expired positions/)
        expect(Rails.logger).to receive(:error).with(/EMERGENCY: Closed 1 expired positions/)

        Position.emergency_close_expired_positions
      end

      it "handles errors gracefully" do
        allow(expired_position).to receive(:force_close!).and_raise(StandardError, "Emergency close error")
        expect(Rails.logger).to receive(:error).with(/Failed to close expired position.*Emergency close error/)

        result = Position.emergency_close_expired_positions
        expect(result).to eq(0)
      end

      it "returns 0 when no expired positions" do
        allow(Position).to receive(:expired_positions).and_return([])

        result = Position.emergency_close_expired_positions
        expect(result).to eq(0)
      end

      it "skips positions without current price" do
        allow(expired_position).to receive(:get_current_market_price).and_return(nil)

        result = Position.emergency_close_expired_positions
        expect(result).to eq(0)
      end
    end
  end
end
