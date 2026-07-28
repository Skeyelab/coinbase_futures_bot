# frozen_string_literal: true

require "rails_helper"

# Issue #535. On 2026-07-28 the #486 calibration ran as a dry-run REHEARSAL —
# which is a designed, legitimate mode — but its abort path treated the
# simulator's own numbers as a measurement of the venue. It reported a "300.0
# bps measured perp taker rate" (a 100x fee bug, #531) and wrote "ADR 0002's
# venue conclusion is FALSIFIED ... contradicted by real fills" into a RISK
# halt. There were no real fills.
#
# Report#adr_verdict already refused to answer ADR 0002 in dry-run. The report
# was honest and the halt was not — which is the worse way round, because the
# halt is what stops trading and what an operator reads first.
RSpec.describe Trading::ExecutionCalibration::AbortConditions, "(issue #535)" do
  def fill(order_id:, commission:)
    Trading::ExecutionCalibration::Fill.new(
      phase: "entry", liquidity: "TAKER", side: "BUY", order_id: order_id,
      intended_price: 100.0, fill_price: 100.0, commission: commission,
      contracts: 1, contract_multiplier: 1, filled_at: Time.current
    )
  end

  # 0.5 on 100.0 notional => 50 bps, well over the 5 bps falsification threshold.
  def tape_with(order_id, commission: 0.5)
    tape = Trading::ExecutionCalibration::Tape.new(product_id: "BIP-20DEC30-CDE")
    tape.add(Trading::ExecutionCalibration::Leg.new(
      number: 1, intent: :taker, entry: fill(order_id: order_id, commission: commission),
      intended_hold_seconds: 10, held_seconds: 10, realized_pnl: 0.0
    ))
    tape
  end

  before do
    allow(TradingHalt).to receive(:halt_for_risk!)
    allow(TradingHalt).to receive(:risk_halted?).and_return(false)
  end

  describe "a dry-run rehearsal" do
    subject(:conditions) do
      described_class.new(tape: tape_with("DRY-RUN-#{SecureRandom.hex(8)}"), mode: :dry_run)
    end

    it "does not claim ADR 0002 is falsified from simulated fills" do
      expect(conditions.detect).to be_nil
    end

    it "raises no risk halt, so a rehearsal cannot stop live trading" do
      conditions.enforce!

      expect(TradingHalt).not_to have_received(:halt_for_risk!)
    end
  end

  describe "a live run" do
    it "still falsifies ADR 0002 when a REAL fill exceeds the threshold" do
      breach = described_class.new(tape: tape_with("CB-REAL-0001"), mode: :live).enforce!

      expect(breach.condition).to eq(:taker_rate)
      expect(breach.reason).to match(/FALSIFIED/)
      expect(breach.halts?).to be(true)
      expect(TradingHalt).to have_received(:halt_for_risk!)
    end

    it "stops when orders are reaching the simulator despite claiming to be live" do
      breach = described_class.new(tape: tape_with("DRY-RUN-abc123"), mode: :live).detect

      expect(breach.condition).to eq(:simulated_fills)
      expect(breach.reason).to match(/SIMULATED/)
    end

    # #540 gave simulated orders unique ids, removing the accidental
    # duplicate-id abort that used to catch this. Detection must not rely on
    # the ids colliding.
    it "catches simulated fills even though #540 made their ids unique" do
      tape = tape_with("DRY-RUN-#{SecureRandom.hex(8)}")
      expect(tape.duplicate_order_ids).to be_empty

      expect(described_class.new(tape: tape, mode: :live).detect.condition).to eq(:simulated_fills)
    end

    it "does not risk-halt for that, because nothing real was placed" do
      breach = described_class.new(tape: tape_with("DRY-RUN-abc123"), mode: :live).enforce!

      expect(breach.halts?).to be(false)
      expect(TradingHalt).not_to have_received(:halt_for_risk!)
    end

    it "leaves a clean live run alone" do
      expect(described_class.new(tape: tape_with("CB-REAL-0002", commission: 0.04), mode: :live).detect)
        .to be_nil
    end
  end
end
