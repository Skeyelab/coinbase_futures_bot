# frozen_string_literal: true

require "rails_helper"

# Extends the #483 freeze guarantee to declarative strategy selection (#303):
# the funding-skew params live in config/strategy_selection.yml, so freezing
# captures that file's fingerprint. A config change during the evidence window
# is then detectable — and the factory alarms on it — instead of silently
# invalidating the #376 gate-2a sample.
RSpec.describe Trading::CalibrationFreeze, "strategy selection drift", type: :service, strategy_selection: true do
  before do
    BotRuntimeStat.where(key: described_class::STORE_KEY).delete_all
  end

  let(:quiet) { Logger.new(IO::NULL) }

  it "captures the strategy-selection fingerprint at freeze! time" do
    described_class.freeze!(reason: "gate-2a", logger: quiet)

    record = BotRuntimeStat.find_by(key: described_class::STORE_KEY)
    expect(record.value["strategy_fingerprint"])
      .to eq(Trading::StrategySelection.fingerprint)
  end

  describe ".strategy_selection_drift" do
    it "is nil when not frozen" do
      expect(described_class.strategy_selection_drift).to be_nil
    end

    it "is nil while the config is unchanged" do
      described_class.freeze!(reason: "gate-2a", logger: quiet)

      expect(described_class.strategy_selection_drift).to be_nil
    end

    it "names both fingerprints when the config changed under freeze" do
      described_class.freeze!(reason: "gate-2a", logger: quiet)
      frozen = Trading::StrategySelection.fingerprint
      allow(Trading::StrategySelection).to receive(:fingerprint).and_return("changed")

      expect(described_class.strategy_selection_drift)
        .to eq(frozen_fingerprint: frozen, current_fingerprint: "changed")
    end

    it "is nil for a legacy freeze that recorded no fingerprint" do
      described_class.write(frozen: true, reason: "old freeze")

      expect(described_class.strategy_selection_drift).to be_nil
    end
  end

  it "surfaces drift in operator status output" do
    described_class.freeze!(reason: "gate-2a", logger: quiet)
    allow(Trading::StrategySelection).to receive(:fingerprint).and_return("changed")

    expect(described_class.status[:strategy_selection_drifted]).to be(true)
  end

  it "reports no drift in status when unfrozen" do
    expect(described_class.status[:strategy_selection_drifted]).to be(false)
  end
end
