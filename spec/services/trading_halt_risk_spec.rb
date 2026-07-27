# frozen_string_literal: true

require "rails_helper"

# Issue #481. Every halt auto-expired after 24 hours, so a RISK-triggered halt
# silently self-resumed and traded again the next day. #392 condition 3 requires
# a cumulative-loss "auto-halt to paper, no override" — unbuildable on a
# primitive that forgets.
#
# The TTL is still right for an operational halt ("pause during the CPI print"),
# which is why this splits the two rather than removing expiry.
RSpec.describe TradingHalt, "risk halts" do
  before { BotRuntimeStat.where(key: described_class::STORE_KEY).delete_all }

  describe "expiry" do
    it "expires an operational halt after the TTL, as before" do
      described_class.halt!(reason: "CPI print")

      travel_to(30.hours.from_now) do
        expect(described_class.active?).to be true
      end
    end

    # The whole point.
    it "never expires a risk halt" do
      described_class.halt_for_risk!(reason: "daily loss cap breached")

      travel_to(30.hours.from_now) { expect(described_class.halted?).to be true }
      travel_to(90.days.from_now) { expect(described_class.halted?).to be true }
    end

    it "keeps blocking order placement past the TTL" do
      described_class.halt_for_risk!(reason: "cumulative tuition cap")

      travel_to(30.hours.from_now) do
        expect { described_class.assert_active!(context: "spec") }
          .to raise_error(described_class::HaltedError, /cumulative tuition cap/)
      end
    end
  end

  describe "clearing" do
    it "refuses to clear a risk halt without explicit acknowledgement" do
      described_class.halt_for_risk!(reason: "weekly loss cap")

      expect { described_class.resume! }.to raise_error(described_class::RiskHaltError)
      expect(described_class.halted?).to be true
    end

    it "clears when the operator acknowledges it" do
      described_class.halt_for_risk!(reason: "weekly loss cap")

      described_class.resume!(acknowledge_risk: true, operator: "edahl")

      expect(described_class.active?).to be true
    end

    # "Requires explicit operator action, and that action is recorded."
    it "records who cleared it and what it was" do
      described_class.halt_for_risk!(reason: "weekly loss cap")
      described_class.resume!(acknowledge_risk: true, operator: "edahl")

      cleared = BotRuntimeStat.find_by(key: described_class::STORE_KEY).value["last_cleared"]
      expect(cleared["operator"]).to eq("edahl")
      expect(cleared["prior_reason"]).to eq("weekly loss cap")
      expect(cleared["prior_kind"]).to eq(described_class::RISK)
      expect(cleared["at"]).to be_present
    end

    it "still clears an operational halt with no ceremony" do
      described_class.halt!(reason: "CPI print")

      expect { described_class.resume! }.not_to raise_error
      expect(described_class.active?).to be true
    end
  end

  describe "status" do
    it "reports the halt kind so an operator can tell the two apart" do
      described_class.halt_for_risk!(reason: "drawdown")

      expect(described_class.status).to include(halted: true, kind: described_class::RISK)
      expect(described_class.risk_halted?).to be true
    end

    it "reports an operational halt as such" do
      described_class.halt!(reason: "maintenance")

      expect(described_class.status[:kind]).to eq(described_class::OPERATIONAL)
      expect(described_class.risk_halted?).to be false
    end
  end

  # A risk halt must win: an operational resume must not quietly undo it.
  it "does not let an operational halt downgrade an active risk halt" do
    described_class.halt_for_risk!(reason: "loss cap")
    described_class.halt!(reason: "unrelated pause")

    expect(described_class.risk_halted?).to be true
    expect { described_class.resume! }.to raise_error(described_class::RiskHaltError)
  end
end
