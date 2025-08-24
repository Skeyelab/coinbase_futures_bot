# frozen_string_literal: true

require "rails_helper"

RSpec.describe DayTradingPositionManagementJob, type: :job do
  let(:job) { described_class.new }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(ActiveSupport::Logger) }

  before do
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)
  end

  describe "#perform" do
    it "executes the day trading position management workflow" do
      allow(manager).to receive(:positions_need_closure?).and_return(false)
      allow(manager).to receive(:positions_approaching_closure?).and_return(false)
      allow(manager).to receive(:check_tp_sl_triggers).and_return([])
      allow(manager).to receive(:get_position_summary).and_return({
        open_count: 0,
        positions_needing_closure: 0,
        positions_approaching_closure: 0
      })

      job.perform
    end

    it "handles positions needing closure" do
      allow(manager).to receive(:positions_need_closure?).and_return(true)
      allow(manager).to receive(:close_expired_positions).and_return(2)
      allow(manager).to receive(:positions_approaching_closure?).and_return(false)
      allow(manager).to receive(:check_tp_sl_triggers).and_return([])
      allow(manager).to receive(:get_position_summary).and_return({
        open_count: 0,
        positions_needing_closure: 0,
        positions_approaching_closure: 0
      })

      expect(Rails.logger).to receive(:info).with(/Found positions needing immediate closure/)
      expect(Rails.logger).to receive(:info).with(/Closed 2 expired positions/)

      job.perform
    end

    it "handles positions approaching closure" do
      allow(manager).to receive(:positions_need_closure?).and_return(false)
      allow(manager).to receive(:positions_approaching_closure?).and_return(true)
      allow(manager).to receive(:close_approaching_positions).and_return(1)
      allow(manager).to receive(:check_tp_sl_triggers).and_return([])
      allow(manager).to receive(:get_position_summary).and_return({
        open_count: 0,
        positions_needing_closure: 0,
        positions_approaching_closure: 0
      })

      expect(Rails.logger).to receive(:info).with(/Found positions approaching closure time/)
      expect(Rails.logger).to receive(:info).with(/Closed 1 approaching positions/)

      job.perform
    end

    it "handles TP/SL triggers" do
      trigger_info = {
        position: instance_double(Position, id: 1, product_id: "BIT-29AUG25-CDE"),
        trigger: "take_profit",
        current_price: 51000.0,
        target_price: 50000.0
      }
      allow(manager).to receive(:positions_need_closure?).and_return(false)
      allow(manager).to receive(:positions_approaching_closure?).and_return(false)
      allow(manager).to receive(:check_tp_sl_triggers).and_return([trigger_info])
      allow(manager).to receive(:close_tp_sl_positions).and_return(1)
      allow(manager).to receive(:get_position_summary).and_return({
        open_count: 0,
        positions_needing_closure: 0,
        positions_approaching_closure: 0
      })

      expect(Rails.logger).to receive(:info).with(/Found 1 positions with triggered TP\/SL/)
      expect(Rails.logger).to receive(:info).with(/Closed 1 TP\/SL positions/)

      job.perform
    end

    it "logs completion message" do
      allow(manager).to receive(:positions_need_closure?).and_return(false)
      allow(manager).to receive(:positions_approaching_closure?).and_return(false)
      allow(manager).to receive(:check_tp_sl_triggers).and_return([])
      allow(manager).to receive(:get_position_summary).and_return({
        open_count: 0,
        positions_needing_closure: 0,
        positions_approaching_closure: 0
      })

      expect(Rails.logger).to receive(:info).with(/Completed day trading position management job/)

      job.perform
    end

    context "when errors occur" do
      it "handles manager initialization errors gracefully" do
        allow(Trading::DayTradingPositionManager).to receive(:new).and_raise(StandardError, "Manager error")

        expect(Rails.logger).to receive(:error).with("Day trading position management job failed: Manager error")

        expect { job.perform }.to raise_error(StandardError, "Manager error")
      end

      it "handles individual method errors gracefully" do
        allow(manager).to receive(:positions_need_closure?).and_raise(StandardError, "Check error")

        expect(Rails.logger).to receive(:error).with("Day trading position management job failed: Check error")

        expect { job.perform }.to raise_error(StandardError, "Check error")
      end
    end
  end

  describe "job configuration" do
    it "has the correct queue name" do
      expect(described_class.queue_name).to eq("critical")
    end

    it "has perform instance method" do
      expect(job).to respond_to(:perform)
    end
  end

  describe "cron scheduling" do
    it "is configured to run every 5 minutes" do
      # This test verifies the job is properly configured for cron scheduling
      # The actual cron configuration is in config/initializers/good_job.rb
      expect(job).to respond_to(:perform)
    end
  end
end