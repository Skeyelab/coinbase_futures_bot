# frozen_string_literal: true

require "rails_helper"

# Issue #535, second pass. The abort path was fixed, then a rehearsal run showed
# the REPORT still making two claims it had not earned:
#
#   reconciliation : WITHIN 10% (0.0% off) — #376 gate 1
#   maker fill rate 0.0% ... this KILLS ADR 0002's +22 bps maker case
#
# Both were derived from the simulator. The first is the model agreeing with
# itself; the second is a claim about a venue queue that a rehearsal has none of.
RSpec.describe Trading::ExecutionCalibration::Report, "a rehearsal claims nothing (issue #535)" do
  def fill(commission:)
    Trading::ExecutionCalibration::Fill.new(
      phase: "entry", liquidity: "TAKER", side: "BUY", order_id: "DRY-RUN-abc",
      intended_price: 100.0, fill_price: 100.0, commission: commission,
      contracts: 1, contract_multiplier: 1, filled_at: Time.current
    )
  end

  def tape
    t = Trading::ExecutionCalibration::Tape.new(product_id: "BIP-20DEC30-CDE")
    t.add(Trading::ExecutionCalibration::Leg.new(
      number: 1, intent: :maker, entry: fill(commission: 0.03),
      intended_hold_seconds: 5, held_seconds: 5, realized_pnl: 0.1
    ))
    t
  end

  def report(mode:, maker_warning: nil)
    described_class.new(
      status: :completed, mode: mode, product_id: "BIP-20DEC30-CDE", tape: tape,
      breach: nil, refusals: [], maker_warning: maker_warning,
      reconciliation: {measured_rate: 0.0003, modeled_rate: 0.0003,
                       within_tolerance: true, relative_drift: 0.0},
      started_at: Time.current, finished_at: Time.current
    )
  end

  describe "in dry-run" do
    subject(:summary) { report(mode: :dry_run).summary }

    it "does not offer the reconciliation as #376 gate 1" do
      expect(summary).to include("CIRCULAR in dry-run")
      expect(summary).to match(/#376 gate 1 is NOT addressed/)
    end

    it "does not claim the maker case is killed or survived" do
      expect(summary).to include("not assessed")
      expect(summary).not_to match(/KILLS/)
      expect(summary).not_to match(/maker case survives/)
    end

    it "still refuses to answer ADR 0002, as it already did" do
      expect(summary).to match(/NOT ANSWERED/)
    end
  end

  describe "in live" do
    it "still reports the reconciliation against #376 gate 1" do
      expect(report(mode: :live).summary).to match(/WITHIN 10%.*#376 gate 1/)
    end

    it "still surfaces a real maker-fill warning" do
      summary = report(mode: :live, maker_warning: "maker fill rate 10.0% ... KILLS the +22 bps case").summary

      expect(summary).to match(/KILLS the \+22 bps case/)
    end

    it "still says the maker case survives when there is no warning" do
      expect(report(mode: :live).summary).to match(/maker case survives/)
    end
  end

  describe Trading::ExecutionCalibration::AbortConditions do
    it "produces no maker warning from a rehearsal" do
      t = Trading::ExecutionCalibration::Tape.new(product_id: "BIP-20DEC30-CDE")
      t.add(Trading::ExecutionCalibration::Leg.new(
        number: 1, intent: :maker, entry: nil,
        intended_hold_seconds: 5, held_seconds: 5, realized_pnl: 0.0
      ))

      expect(described_class.new(tape: t, mode: :dry_run).maker_fill_rate_warning).to be_nil
      expect(described_class.new(tape: t, mode: :live).maker_fill_rate_warning).to match(/KILLS/)
    end
  end
end
