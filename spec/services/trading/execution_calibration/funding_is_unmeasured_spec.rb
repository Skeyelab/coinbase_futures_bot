# frozen_string_literal: true

require "rails_helper"

# Nothing in the codebase ever ASSIGNS Leg#funding_debited — funding is settled
# out of band by the venue and never appears on the order path this run reads.
# Tape summed nils to 0.0, so a hold that crossed a funding boundary reported
# "modeled $+0.0123 vs debited $+0.0000". That zero is the ABSENCE of a
# measurement formatted as one, and it made the "not observable" branch dead.
RSpec.describe "funding is unmeasured, and must say so (issue #486)" do
  def leg(funding_modeled:, funding_debited: nil)
    Trading::ExecutionCalibration::Leg.new(
      number: 1, intent: :taker, intended_hold_seconds: 3900, held_seconds: 3900,
      realized_pnl: 0.0, funding_modeled: funding_modeled, funding_debited: funding_debited
    )
  end

  def tape_with(*legs)
    t = Trading::ExecutionCalibration::Tape.new(product_id: "BIP-20DEC30-CDE")
    legs.each { |l| t.add(l) }
    t
  end

  def report_for(tape, mode:)
    Trading::ExecutionCalibration::Report.new(
      status: :completed, mode: mode, product_id: "BIP-20DEC30-CDE", tape: tape,
      breach: nil, refusals: [], maker_warning: nil, reconciliation: nil,
      started_at: Time.current, finished_at: Time.current
    )
  end

  describe Trading::ExecutionCalibration::Tape do
    it "reports nil rather than 0.0 when nothing was ever debited" do
      expect(tape_with(leg(funding_modeled: 0.0123)).funding_debited).to be_nil
    end

    it "sums real debits when they exist" do
      tape = tape_with(leg(funding_modeled: 0.01, funding_debited: 0.02),
        leg(funding_modeled: 0.01, funding_debited: 0.03))

      expect(tape.funding_debited).to be_within(1e-9).of(0.05)
    end
  end

  describe "the funding line" do
    it "says nothing was measured when no boundary was crossed" do
      summary = report_for(tape_with(leg(funding_modeled: 0.0)), mode: :live).summary

      expect(summary).to match(/no funding boundary was crossed/)
      expect(summary).to match(/UNMEASURED/)
    end

    # The case the longer-hold run would have produced.
    it "does not present a crossed boundary in dry-run as a measurement" do
      summary = report_for(tape_with(leg(funding_modeled: 0.0123)), mode: :dry_run).summary

      expect(summary).to match(/debited NOTHING/)
      expect(summary).to match(/not a measurement/)
      expect(summary).not_to match(/vs debited \$\+0\.0000/)
    end

    it "says funding is not observable from the order path on a live run" do
      summary = report_for(tape_with(leg(funding_modeled: 0.0123)), mode: :live).summary

      expect(summary).to match(/NOT OBSERVABLE/)
      expect(summary).to match(/settled out of band/)
    end

    it "reports a real comparison once a debit is actually recorded" do
      tape = tape_with(leg(funding_modeled: 0.0123, funding_debited: 0.0100))

      expect(report_for(tape, mode: :live).summary).to match(/modeled \$\+0\.0123 vs debited \$\+0\.0100/)
    end
  end

  describe "the JSON payload" do
    it "distinguishes a crossed boundary from an actual measurement" do
      f = report_for(tape_with(leg(funding_modeled: 0.0123)), mode: :live).to_h[:funding]

      expect(f[:boundary_crossed]).to be(true)
      expect(f[:measured]).to be(false)
      expect(f[:debited_usd]).to be_nil
    end
  end
end
