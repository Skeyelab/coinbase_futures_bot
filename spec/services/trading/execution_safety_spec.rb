# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::ExecutionSafety, type: :service do
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }

  describe ".enforce_paper_default!" do
    it "leaves live execution alone when LIVE_TRADING_CONFIRMED=1" do
      DryRun.disable!
      ClimateControl.modify(LIVE_TRADING_CONFIRMED: "1") do
        expect(described_class.enforce_paper_default!(logger: logger)).to eq(:live)
      end
      expect(DryRun.active?).to be false
    end

    it "reports :paper when dry-run is already active" do
      DryRun.enable!
      ClimateControl.modify(LIVE_TRADING_CONFIRMED: nil) do
        expect(described_class.enforce_paper_default!(logger: logger)).to eq(:paper)
      end
      expect(DryRun.active?).to be true
    end

    it "forces dry-run ON when live trading is not confirmed" do
      DryRun.disable!
      ClimateControl.modify(LIVE_TRADING_CONFIRMED: nil) do
        expect(described_class.enforce_paper_default!(logger: logger)).to eq(:forced_paper)
      end
      expect(DryRun.active?).to be true
      expect(logger).to have_received(:warn).with(/forcing DRY-RUN/i)
    end

    it "treats any value other than exactly \"1\" as unconfirmed" do
      DryRun.disable!
      ClimateControl.modify(LIVE_TRADING_CONFIRMED: "true") do
        expect(described_class.enforce_paper_default!(logger: logger)).to eq(:forced_paper)
      end
      expect(DryRun.active?).to be true
    end
  end
end
