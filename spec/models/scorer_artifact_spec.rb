# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScorerArtifact do
  def build_artifact(version: "logistic-long-v1")
    described_class.new(
      version: version,
      direction: "long",
      timeframe: "5m",
      tp_frac: 0.020,
      sl_frac: 0.012,
      horizon: 288,
      feature_spec: {
        "feature_names" => %w[trend_1h align_5m],
        "symbols" => %w[BIP-20DEC30-CDE ETP-20DEC30-CDE],
        "baseline_symbol" => "BIP-20DEC30-CDE",
        "standardization" => {"means" => {"trend_1h" => 0.0, "align_5m" => 0.0},
                              "stds" => {"trend_1h" => 1.0, "align_5m" => 1.0}}
      },
      coefficients: {"intercept" => -0.5, "weights" => {"trend_1h" => 1.2, "align_5m" => -0.3,
                                                        "symbol=ETP-20DEC30-CDE" => 0.1}},
      training_metadata: {"train_rows" => 1000}
    )
  end

  it "persists and reloads the full artifact payload" do
    artifact = build_artifact.tap(&:save!)

    reloaded = described_class.find(artifact.id)
    expect(reloaded.coefficients["weights"]["trend_1h"]).to eq(1.2)
    expect(reloaded.feature_spec["feature_names"]).to eq(%w[trend_1h align_5m])
    expect(reloaded.horizon).to eq(288)
  end

  it "enforces version uniqueness" do
    build_artifact.tap(&:save!)

    expect { build_artifact.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "validates direction" do
    artifact = build_artifact
    artifact.direction = "sideways"
    expect(artifact).not_to be_valid
  end

  describe "freezing (#483 discipline)" do
    it "is mutable before freezing" do
      artifact = build_artifact.tap(&:save!)

      expect { artifact.update!(training_metadata: {"train_rows" => 2000}) }.not_to raise_error
      expect(artifact.frozen_artifact?).to be(false)
    end

    it "freeze_artifact! stamps frozen_at" do
      artifact = build_artifact.tap(&:save!)

      artifact.freeze_artifact!

      expect(artifact.frozen_artifact?).to be(true)
      expect(artifact.reload.frozen_at).to be_present
    end

    it "refuses any update once frozen" do
      artifact = build_artifact.tap(&:save!)
      artifact.freeze_artifact!

      expect { artifact.update!(coefficients: {"intercept" => 0.0, "weights" => {}}) }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(artifact.reload.coefficients["intercept"]).to eq(-0.5)
    end

    it "refuses updates on a freshly-loaded frozen record too" do
      artifact = build_artifact.tap(&:save!)
      artifact.freeze_artifact!

      reloaded = described_class.find(artifact.id)
      expect { reloaded.update!(direction: "short") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses destroy once frozen" do
      artifact = build_artifact.tap(&:save!)
      artifact.freeze_artifact!

      expect { artifact.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(described_class.exists?(artifact.id)).to be(true)
    end

    it "cannot be re-frozen (frozen_at never moves)" do
      artifact = build_artifact.tap(&:save!)
      artifact.freeze_artifact!
      first_stamp = artifact.reload.frozen_at

      expect { artifact.freeze_artifact! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(artifact.reload.frozen_at).to eq(first_stamp)
    end
  end
end
