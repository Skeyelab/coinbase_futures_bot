# frozen_string_literal: true

require "rails_helper"

RSpec.describe DryRun do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }

  describe "#active?" do
    it "is inactive by default (live execution)" do
      expect(described_class.active?).to be false
    end

    it "is active after enable!" do
      described_class.enable!(logger: logger)
      expect(described_class.active?).to be true
    end

    it "is inactive again after disable!" do
      described_class.enable!(logger: logger)
      described_class.disable!(logger: logger)
      expect(described_class.active?).to be false
    end
  end

  describe "cross-process durability" do
    it "persists in bot_runtime_stats and is visible to a freshly constructed instance" do
      described_class.new(logger: logger).enable!

      expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_present
      expect(described_class.new(logger: logger).active?).to be true
    end
  end

  describe "no auto-expiry" do
    it "stays active even when the record is very old (never silently returns to live)" do
      described_class.enable!(logger: logger)
      BotRuntimeStat.find_by(key: described_class::STORE_KEY).update!(recorded_at: 90.days.ago)

      expect(described_class.active?).to be true
    end
  end

  describe "#status" do
    it "reports active state and a timestamp" do
      described_class.enable!(logger: logger)

      status = described_class.status
      expect(status[:active]).to be true
      expect(status[:as_of]).to be_present
    end
  end
end
