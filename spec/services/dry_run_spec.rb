# frozen_string_literal: true

require "rails_helper"

RSpec.describe DryRun do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }

  describe "#active?" do
    # 2026-07-29: two real BIP orders filled minutes after a service restart,
    # while the operator believed dry-run was on. A missing or unreadable
    # dry_run record must read as PAPER — unknown state is not permission to
    # send real orders.
    it "is ACTIVE when no record exists (unknown state fails closed to paper)" do
      expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_nil
      expect(described_class.active?).to be true
    end

    it "is active after enable!" do
      described_class.enable!(logger: logger)
      expect(described_class.active?).to be true
    end

    it "is inactive after a CONFIRMED disable!" do
      described_class.enable!(logger: logger)
      described_class.disable!(confirm: "LIVE", reason: "spec", logger: logger)
      expect(described_class.active?).to be false
    end

    it "refuses to disable without the confirmation phrase" do
      described_class.enable!(logger: logger)

      expect { described_class.disable!(logger: logger) }
        .to raise_error(DryRun::UnconfirmedDisable)
      expect(described_class.active?).to be true
    end
  end

  describe "audit trail" do
    it "appends every transition with reason and timestamp" do
      described_class.enable!(logger: logger)
      described_class.disable!(confirm: "LIVE", reason: "gate 2a fill test", logger: logger)

      history = BotRuntimeStat.find_by(key: described_class::STORE_KEY).value["history"]
      expect(history.size).to eq(2)
      expect(history.last).to include("enabled" => false, "reason" => "gate 2a fill test")
      expect(history.last["at"]).to be_present
    end

    it "keeps the trail bounded" do
      25.times { described_class.enable!(logger: logger) }

      history = BotRuntimeStat.find_by(key: described_class::STORE_KEY).value["history"]
      expect(history.size).to eq(20)
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
