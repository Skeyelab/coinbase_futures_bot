# frozen_string_literal: true

require "rails_helper"

# Issue #483. CalibrationJob runs nightly at 02:00 UTC and calls activate!,
# mutating the tp/sl the live path reads. #376 gate 2 requires a sample under a
# FROZEN config, so the config was being silently unfrozen every night and no
# sample gathered so far is gate-eligible.
RSpec.describe Trading::CalibrationFreeze, type: :service do
  before { BotRuntimeStat.where(key: described_class::STORE_KEY).delete_all }

  it "is unfrozen by default — this must be opt-in" do
    expect(described_class.frozen?).to be false
  end

  it "freezes with a recorded reason" do
    described_class.freeze!(reason: "gate 2a evidence window", logger: Logger.new(IO::NULL))

    expect(described_class.frozen?).to be true
    expect(described_class.reason).to eq("gate 2a evidence window")
    expect(described_class.status).to include(frozen: true)
  end

  it "unfreezes" do
    described_class.freeze!(reason: "x", logger: Logger.new(IO::NULL))
    described_class.unfreeze!(logger: Logger.new(IO::NULL))

    expect(described_class.frozen?).to be false
  end

  # Durable, like TradingHalt and DryRun: a restart must not silently unfreeze
  # a config that a gate sample depends on.
  it "survives a fresh read of the store" do
    described_class.freeze!(reason: "window open", logger: Logger.new(IO::NULL))

    expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY).value["frozen"]).to be true
  end

  # Acceptance: a frozen config must be visible, or an operator reads a stale
  # tp/sl in status and cannot tell why calibration stopped moving it.
  describe "operator visibility" do
    it "appears in the operator status snapshot" do
      described_class.freeze!(reason: "gate 2a window", logger: Logger.new(IO::NULL))

      status = OperatorSnapshot.new.status

      expect(status[:calibration_freeze]).to include(frozen: true, reason: "gate 2a window")
    end

    it "reports unfrozen when it is not set" do
      expect(OperatorSnapshot.new.status[:calibration_freeze]).to include(frozen: false)
    end
  end
end
