# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealTimeMonitoringJob, type: :job do
  let(:session) { instance_double(RealtimeMonitoring::Session) }

  before do
    allow(RealtimeMonitoring::Session).to receive(:new).and_return(session)
    allow(Rails.logger).to receive(:warn)
  end

  describe "job configuration" do
    it "uses the critical queue" do
      expect(described_class.queue_name).to eq("critical")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "#perform" do
    it "delegates to a blocking realtime monitoring session" do
      expect(session).to receive(:run_blocking).with(
        product_ids: nil,
        futures_product_ids: nil,
        spot_product_ids: nil
      ).and_return({success: true})

      described_class.perform_now
    end

    it "logs when the session fails to start" do
      allow(session).to receive(:run_blocking).and_return({success: false, error: "No products"})

      expect(Rails.logger).to receive(:warn).with("[RTM] No products")

      described_class.perform_now(product_ids: ["BTC-USD"])
    end
  end
end
