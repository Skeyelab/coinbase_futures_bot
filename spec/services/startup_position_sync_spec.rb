# frozen_string_literal: true

require "rails_helper"

RSpec.describe StartupPositionSync do
  let(:import_service) { instance_double(PositionImportService) }
  let(:logger) { instance_double(Logger, warn: true) }
  let(:env) { ActiveSupport::HashWithIndifferentAccess.new }
  let(:service) { described_class.new(import_service: import_service, logger: logger, env: env) }

  describe "#call" do
    it "returns success details when import succeeds" do
      allow(import_service).to receive(:import_positions_from_coinbase).and_return(
        imported: 1,
        updated: 2,
        reconciled: 1,
        total_coinbase: 4
      )

      result = service.call

      expect(result.status).to eq(:ok)
      expect(result.message).to eq("Positions synced from Coinbase (1 new, 2 updated, 1 reconciled, 4 on exchange)")
    end

    it "skips when FUTURESBOT_SKIP_POSITION_SYNC is set" do
      env["FUTURESBOT_SKIP_POSITION_SYNC"] = "1"

      result = service.call

      expect(result.status).to eq(:skipped)
      expect(import_service).not_to receive(:import_positions_from_coinbase)
    end

    it "returns an error result when import fails" do
      allow(import_service).to receive(:import_positions_from_coinbase).and_raise(StandardError, "boom")

      result = service.call

      expect(result.status).to eq(:error)
      expect(result.message).to eq("Position sync skipped: boom")
      expect(logger).to have_received(:warn).with("[StartupPositionSync] boom")
    end
  end
end
