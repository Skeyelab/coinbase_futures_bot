# frozen_string_literal: true

require "rails_helper"

# Intraday-only was a single global flag inherited from #392 condition 4, which
# reasoned about DATED metals. A perp has no session and no roll, so there is
# nothing to be flat before — and the measured 200/120 configuration (#496)
# holds ~16.6h, which nightly flattening would truncate.
RSpec.describe Trading::HoldHorizon, type: :service do
  let(:perp) { "BIP-20DEC30-CDE" }
  let(:dated) { "NOL-19AUG26-CDE" }

  before do
    FundingRate.create!(product_id: perp, funding_time: 1.hour.ago, funding_rate: 0.000013,
      funding_interval_seconds: 3600, observed_at: 1.hour.ago)
  end

  it "lets a perp hold past the session boundary" do
    expect(described_class.day_trading?(perp)).to be false
  end

  # Session hours, overnight margin step-ups and roll risk are real here — this
  # is what #392 was actually reasoning about.
  it "keeps a dated contract intraday" do
    expect(described_class.day_trading?(dated)).to be true
  end

  it "falls back to the global default when there is no product" do
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    expect(described_class.day_trading?(nil)).to be true

    allow(Rails.application.config).to receive(:default_day_trading).and_return(false)
    expect(described_class.day_trading?("")).to be false
  end

  # A venue lookup that raises must not decide the horizon by accident.
  # Asserted with the default set to FALSE: a nil venue result is falsy, so a
  # naive `return false if perp?(...)` would answer true here and look correct
  # for the wrong reason.
  it "falls back to the global default when the venue cannot be determined" do
    allow(CostModel).to receive(:perp?).and_raise(ActiveRecord::StatementInvalid, "db gone")

    allow(Rails.application.config).to receive(:default_day_trading).and_return(false)
    expect(described_class.day_trading?(perp)).to be false

    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    expect(described_class.day_trading?(perp)).to be true
  end
end
