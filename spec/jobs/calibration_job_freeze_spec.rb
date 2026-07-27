# frozen_string_literal: true

require "rails_helper"

# Issue #483: freezing suspends ACTIVATION, not calibration. The search keeps
# running and keeps recording its winner, so nothing is lost — it simply stops
# rewriting what the live strategy reads mid-sample.
RSpec.describe CalibrationJob, "under calibration freeze" do
  let(:job) { described_class.new }
  let(:best) { {tp_target: 0.02, sl_target: 0.012, score: 12.3, aggregate: {}} }

  before do
    BotRuntimeStat.where(key: Trading::CalibrationFreeze::STORE_KEY).delete_all
    TradingProfile.delete_all
  end

  def activate!
    job.send(:persist_profile, "BIP-20DEC30-CDE", best, 17)
  end

  context "when not frozen" do
    it "activates the winning profile" do
      profile = activate!

      expect(profile.reload).to be_active
      expect(TradingProfile.active_profile("BIP-20DEC30-CDE")).to eq(profile)
    end
  end

  context "when frozen" do
    before { Trading::CalibrationFreeze.freeze!(reason: "evidence window", logger: Logger.new(IO::NULL)) }

    it "records the winner without activating it" do
      profile = activate!

      expect(profile).to be_persisted
      expect(profile.reload).not_to be_active
      expect(TradingProfile.active_profile("BIP-20DEC30-CDE")).to be_nil
    end

    # The point of freezing: what the live strategy reads must not move.
    # Asserted for the SYMBOL, which is what calibration writes. Checking the
    # global profile would pass either way — calibration never touches it.
    it "leaves the live effective config for that symbol untouched" do
      existing = create(:trading_profile, :active, name: "frozen-live",
        symbol: "BIP-20DEC30-CDE", tp_target: 0.02, sl_target: 0.012)

      activate!

      effective = TradingProfile.effective(symbol: "BIP-20DEC30-CDE")
      expect(effective.id).to eq(existing.id)
      expect(effective.tp_target.to_f).to eq(0.02)
    end
  end
end
