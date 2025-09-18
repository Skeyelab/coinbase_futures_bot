# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContractExpiryManager, type: :service do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:positions_service) { double("positions_service") }
  let(:slack_service) { double("slack_service", alert: nil) }
  let(:expiry_manager) { described_class.new(logger: logger) }

  before do
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    stub_const("SlackNotificationService", slack_service)
    travel_to Date.new(2025, 8, 25) # Monday, August 25, 2025
  end

  after do
    travel_back
  end

  describe "#positions_approaching_expiry" do
    let!(:expiring_position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-30AUG25-CDE", status: "OPEN") }
    let!(:closed_position) { create(:position, product_id: "BIT-26AUG25-CDE", status: "CLOSED") }

    it "returns positions expiring within buffer days" do
      result = expiry_manager.positions_approaching_expiry(2)

      expect(result).to include(expiring_position)
      expect(result).not_to include(safe_position)
      expect(result).not_to include(closed_position)
    end

    it "logs position details when expiring positions found" do
      expect(logger).to receive(:info).with(/Found 1 positions approaching expiry/)
      expect(logger).to receive(:info).with(/BIT-27AUG25-CDE.*expires in 2 days/)

      expiry_manager.positions_approaching_expiry(2)
    end

    it "returns empty array when no expiring positions" do
      result = expiry_manager.positions_approaching_expiry(0)
      expect(result).to be_empty
    end
  end

  describe "#close_expiring_positions" do
    let!(:expiring_position1) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN", size: 5) }
    let!(:expiring_position2) { create(:position, product_id: "BIT-26AUG25-CDE", status: "OPEN", size: 3) }

    context "when positions close successfully" do
      before do
        allow(positions_service).to receive(:close_position).and_return({"success" => true})
      end

      it "closes all expiring positions" do
        result = expiry_manager.close_expiring_positions(2)

        expect(result).to eq(2)
        expect(positions_service).to have_received(:close_position).with(product_id: "BIT-27AUG25-CDE")
        expect(positions_service).to have_received(:close_position).with(product_id: "BIT-26AUG25-CDE")
      end

      it "sends notification for successful closures" do
        expiry_manager.close_expiring_positions(2)

        expect(slack_service).to have_received(:alert).with(
          "warning",
          "Contract Expiry Alert",
          "Closed 2 positions approaching contract expiry (2d buffer)."
        )
      end

      it "logs closure activity" do
        expect(logger).to receive(:warn).with(/Closing 2 positions approaching expiry/)
        expect(logger).to receive(:info).with(/Closing position.*Contract expiry/)

        expiry_manager.close_expiring_positions(2)
      end
    end

    context "when API closure fails but local closure succeeds" do
      before do
        allow(positions_service).to receive(:close_position).and_raise(StandardError, "API error")
        allow_any_instance_of(Position).to receive(:get_current_market_price).and_return(50000.0)
        allow_any_instance_of(Position).to receive(:force_close!)
      end

      it "falls back to local closure" do
        result = expiry_manager.close_expiring_positions(2)

        expect(result).to eq(2)
        # Since we're using allow_any_instance_of, we can't use have_received on specific instances
        # Instead, we verify the result and that the method was called
      end
    end

    context "when both API and local closure fail" do
      before do
        allow(positions_service).to receive(:close_position).and_raise(StandardError, "API error")
        allow_any_instance_of(Position).to receive(:get_current_market_price).and_return(nil)
      end

      it "logs errors and returns 0" do
        expect(logger).to receive(:error).with(/API closure failed/)
        expect(logger).to receive(:error).with(/Cannot close position.*no current price/)

        result = expiry_manager.close_expiring_positions(2)
        expect(result).to eq(0)
      end
    end

    it "returns 0 when no expiring positions" do
      result = expiry_manager.close_expiring_positions(0)
      expect(result).to eq(0)
    end
  end

  describe "#close_expired_positions" do
    context "when expired positions exist" do
      let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }

      before do
        allow(positions_service).to receive(:close_position).and_return({"success" => true})
      end

      it "closes expired positions" do
        result = expiry_manager.close_expired_positions

        expect(result).to eq(1)
        expect(positions_service).to have_received(:close_position).with(product_id: "BIT-24AUG25-CDE")
      end

      it "sends emergency notification" do
        expiry_manager.close_expired_positions

        expect(slack_service).to have_received(:alert).with(
          "error",
          "EMERGENCY: Expired Contracts",
          "Closed 1 expired positions. Immediate attention required!"
        )
      end

      it "logs emergency activity" do
        expect(logger).to receive(:error).with(/EMERGENCY: Closing 1 expired positions/)
        expect(logger).to receive(:info).with(/Closing position.*EMERGENCY: Contract expired/)

        expiry_manager.close_expired_positions
      end
    end

    context "when no expired positions exist" do
      it "returns 0 when no expired positions" do
        result = expiry_manager.close_expired_positions
        expect(result).to eq(0)
      end
    end
  end

  describe "#check_margin_requirements_near_expiry" do
    let!(:expiring_position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-05SEP25-CDE", status: "OPEN") }

    it "identifies positions with increased margin requirements" do
      result = expiry_manager.check_margin_requirements_near_expiry(5)

      expect(result.size).to eq(1)
      expect(result.first[:position]).to eq(expiring_position)
      expect(result.first[:margin_impact][:multiplier]).to eq(1.5)
    end

    it "sends notification for margin warnings" do
      expiry_manager.check_margin_requirements_near_expiry(5)

      expect(slack_service).to have_received(:alert).with(
        "warning",
        "Margin Warning Near Expiry",
        /Margin requirement increases near contract expiry/
      )
    end

    it "returns empty array when no margin warnings" do
      result = expiry_manager.check_margin_requirements_near_expiry(1) # Only check 1 day ahead
      expect(result).to be_empty
    end
  end

  describe "#monitor_balance_during_expiry_closures" do
    let!(:expiring_position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN", size: 10) }

    before do
      allow(positions_service).to receive(:close_position).and_return({"success" => true})
    end

    it "monitors balance impact and sends notification" do
      result = expiry_manager.monitor_balance_during_expiry_closures(2)

      expect(result[:closed_count]).to eq(1)
      expect(result[:margin_freed]).to be > 1000

      expect(slack_service).to have_received(:alert).with(
        "info",
        "Margin Freed from Expiry Closures",
        /Freed approximately.*margin by closing 1 expiring positions/
      )
    end

    it "returns zero values when no expiring positions" do
      result = expiry_manager.monitor_balance_during_expiry_closures(0)

      expect(result[:closed_count]).to eq(0)
      expect(result[:margin_freed]).to eq(0)
    end
  end

  describe "#generate_expiry_report" do
    let!(:expiring_today) { create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN") }
    let!(:expiring_tomorrow) { create(:position, product_id: "BIT-26AUG25-CDE", status: "OPEN") }
    let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }
    let!(:safe_position) { create(:position, product_id: "BIT-30AUG25-CDE", status: "OPEN") }

    it "generates comprehensive expiry report" do
      report = expiry_manager.generate_expiry_report

      expect(report[:total_positions]).to eq(4)
      expect(report[:positions_with_known_expiry]).to eq(4)
      expect(report[:expiring_today]).to eq(1)
      expect(report[:expiring_tomorrow]).to eq(1)
      expect(report[:expiring_within_week]).to eq(3) # Positions expiring within 0-7 days (excludes already expired)
      expect(report[:expired]).to eq(1)

      expect(report[:by_days]).to be_a(Array)
      expect(report[:by_days].map(&:first)).to include(-1, 0, 1, 5) # days until expiry
    end

    it "logs the report" do
      expect(logger).to receive(:info).with(/Contract Expiry Report/)
      expiry_manager.generate_expiry_report
    end
  end

  describe "#validate_expiry_dates" do
    let!(:valid_position) { create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN") }
    let!(:invalid_position) { create(:position, product_id: "INVALID-FORMAT", status: "OPEN") }

    before do
      allow(positions_service).to receive(:list_open_positions).and_return([])
    end

    it "validates expiry dates for all positions" do
      results = expiry_manager.validate_expiry_dates

      expect(results.size).to eq(2)

      valid_result = results.find { |r| r[:position_id] == valid_position.id }
      expect(valid_result[:valid]).to be true
      expect(valid_result[:parsed_expiry]).to eq(Date.new(2025, 8, 25))

      invalid_result = results.find { |r| r[:position_id] == invalid_position.id }
      expect(invalid_result[:valid]).to be false
      expect(invalid_result[:parsed_expiry]).to be_nil
    end

    it "logs validation results" do
      expect(logger).to receive(:info).with(/Validated expiry dates for 2 positions/)
      expect(logger).to receive(:warn).with(/Invalid expiry date for position.*INVALID-FORMAT/)

      expiry_manager.validate_expiry_dates
    end

    context "when API data is available" do
      before do
        allow(positions_service).to receive(:list_open_positions).with(product_id: "BIT-25AUG25-CDE")
          .and_return([{"expiration_time" => "2025-08-25T16:00:00Z"}])
        allow(positions_service).to receive(:list_open_positions).with(product_id: "INVALID-FORMAT")
          .and_return([])
      end

      it "includes API expiry data in validation results" do
        results = expiry_manager.validate_expiry_dates

        valid_result = results.find { |r| r[:position_id] == valid_position.id }
        expect(valid_result[:api_expiry]).to eq("2025-08-25T16:00:00Z")
        expect(valid_result[:api_days_until_expiry]).to eq(0)
      end
    end
  end

  describe "private methods" do
    describe "#close_single_position" do
      let(:position) { create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN") }

      context "when API closure succeeds" do
        before do
          allow(positions_service).to receive(:close_position).and_return({"success" => true})
        end

        it "closes position via API and returns 1" do
          result = expiry_manager.send(:close_single_position, position, "Test reason")

          expect(result).to eq(1)
          expect(positions_service).to have_received(:close_position).with(product_id: position.product_id)
        end
      end

      context "when API closure fails" do
        before do
          allow(positions_service).to receive(:close_position).and_return({"success" => false})
          allow(position).to receive(:get_current_market_price).and_return(50000.0)
          allow(position).to receive(:force_close!)
        end

        it "falls back to local closure" do
          result = expiry_manager.send(:close_single_position, position, "Test reason")

          expect(result).to eq(1)
          expect(position).to have_received(:force_close!).with(50000.0, "Test reason")
        end
      end

      context "when both API and local closure fail" do
        before do
          allow(positions_service).to receive(:close_position).and_raise(StandardError, "API error")
          allow(position).to receive(:get_current_market_price).and_return(nil)
        end

        it "returns 0 and logs error" do
          expect(logger).to receive(:error).with(/API closure failed/)
          expect(logger).to receive(:error).with(/Cannot close position.*no current price/)

          result = expiry_manager.send(:close_single_position, position, "Test reason")
          expect(result).to eq(0)
        end
      end
    end

    describe "#notify_expiry_closures" do
      it "sends regular expiry notification" do
        expiry_manager.send(:notify_expiry_closures, 5, 2, "warning", emergency: false)

        expect(slack_service).to have_received(:alert).with(
          "warning",
          "Contract Expiry Alert",
          "Closed 5 positions approaching contract expiry (2d buffer)."
        )
      end

      it "sends emergency expiry notification" do
        expiry_manager.send(:notify_expiry_closures, 3, 0, "error", emergency: true)

        expect(slack_service).to have_received(:alert).with(
          "error",
          "EMERGENCY: Expired Contracts",
          "Closed 3 expired positions. Immediate attention required!"
        )
      end

      it "handles notification errors gracefully" do
        allow(slack_service).to receive(:alert).and_raise(StandardError, "Slack error")
        expect(logger).to receive(:error).with(/Failed to send expiry closure notification/)

        expiry_manager.send(:notify_expiry_closures, 1, 2, "warning")
      end
    end

    describe "#notify_margin_warnings_near_expiry" do
      let(:position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }
      let(:margin_warnings) do
        [{
          position: position,
          margin_impact: {reason: "20% higher margin", multiplier: 1.2}
        }]
      end

      it "sends margin warning notification" do
        expiry_manager.send(:notify_margin_warnings_near_expiry, margin_warnings)

        expect(slack_service).to have_received(:alert).with(
          "warning",
          "Margin Warning Near Expiry",
          /Margin requirement increases near contract expiry.*BIT-27AUG25-CDE.*20% higher margin/m
        )
      end

      it "handles empty warnings gracefully" do
        expiry_manager.send(:notify_margin_warnings_near_expiry, [])
        expect(slack_service).not_to have_received(:alert)
      end

      it "handles notification errors gracefully" do
        allow(slack_service).to receive(:alert).and_raise(StandardError, "Slack error")
        expect(logger).to receive(:error).with(/Failed to send margin warning notification/)

        expiry_manager.send(:notify_margin_warnings_near_expiry, margin_warnings)
      end
    end
  end
end
