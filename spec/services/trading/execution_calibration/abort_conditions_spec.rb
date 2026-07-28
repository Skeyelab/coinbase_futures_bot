# frozen_string_literal: true

require "rails_helper"

# Every abort condition in issue #486 gets a spec that proves it HALTS, not
# merely that it was detected. This codebase has shipped inert safety twice
# (#396-#401 wrote locks nothing read; two emergency stops reported closes they
# never made), and an abort condition that has never been exercised is the same
# pattern with a different name.
RSpec.describe Trading::ExecutionCalibration::AbortConditions do
  let(:product_id) { "BIP-20DEC30-CDE" }
  let(:tape) { Trading::ExecutionCalibration::Tape.new(product_id: product_id) }
  let(:logger) { instance_spy(Logger) }

  subject(:conditions) { described_class.new(tape: tape, logger: logger) }

  before { BotRuntimeStat.delete_all }

  # A clean taker leg: filled at the intended price, 1 contract, 3 bps
  # commission on ~$659 of notional.
  def clean_leg(number: 1, intent: :taker, liquidity: "TAKER", **overrides)
    Trading::ExecutionCalibration::Leg.new(
      number: number,
      intent: intent,
      intended_hold_seconds: 30,
      held_seconds: 31,
      realized_pnl: -0.40,
      entry: fill(phase: :entry, liquidity: liquidity, order_id: "o#{number}e"),
      exit: fill(phase: :exit, liquidity: "TAKER", order_id: "o#{number}x"),
      **overrides
    )
  end

  def fill(phase:, liquidity:, order_id:, intended_price: 65_900.0, fill_price: 65_900.0,
    commission: 0.198, contracts: 1.0, contract_multiplier: 0.01)
    Trading::ExecutionCalibration::Fill.new(
      phase: phase, liquidity: liquidity, order_id: order_id, side: (phase == :entry) ? "BUY" : "SELL",
      intended_price: intended_price, fill_price: fill_price, commission: commission,
      contracts: contracts, contract_multiplier: contract_multiplier
    )
  end

  it "finds no breach on a clean run" do
    3.times { |i| tape.add(clean_leg(number: i + 1)) }

    expect(conditions.enforce!).to be_nil
    expect(TradingHalt.risk_halted?).to be(false)
  end

  describe "abort: any single fill slippage > 25 bps" do
    it "halts, non-expiring, on a fill that slipped past 25 bps" do
      # 66,100 against an intended 65,900 is ~30 bps adverse on a buy.
      tape.add(clean_leg(number: 1).tap { |l| l.entry.fill_price = 66_100.0 })

      breach = conditions.enforce!

      expect(breach.condition).to eq(:slippage)
      expect(TradingHalt.risk_halted?).to be(true)
      expect(TradingHalt.status[:reason]).to include("slippage")
    end

    it "does not halt at 25 bps or below" do
      tape.add(clean_leg(number: 1).tap { |l| l.entry.fill_price = 66_000.0 })

      expect(conditions.enforce!).to be_nil
      expect(TradingHalt.risk_halted?).to be(false)
    end
  end

  describe "abort: measured taker rate > 5 bps" do
    # This is the abort that matters most: ADR 0002's entire venue thesis
    # (dated -9 bps -> perp +15 bps) rests on ~3 bps taker.
    it "halts and says in words that ADR 0002's venue conclusion is FALSIFIED" do
      # $4.00 on ~$659 of notional is ~61 bps.
      tape.add(clean_leg(number: 1).tap { |l| l.entry.commission = 4.0 })

      breach = conditions.enforce!

      expect(breach.condition).to eq(:taker_rate)
      expect(breach.reason).to include("FALSIFIED")
      expect(breach.reason).to include("ADR 0002")
      expect(TradingHalt.risk_halted?).to be(true)
      expect(TradingHalt.status[:reason]).to include("FALSIFIED")
    end

    it "does not halt at the modeled ~3 bps" do
      3.times { |i| tape.add(clean_leg(number: i + 1)) }

      expect(conditions.enforce!).to be_nil
    end

    # Maker fills are 0% by design; averaging them into the taker rate would
    # hide a bad taker rate behind free maker fills.
    it "measures the taker rate from taker fills only" do
      tape.add(clean_leg(number: 1, intent: :maker, liquidity: "MAKER").tap do |l|
        l.entry.commission = 0.0
        l.exit.commission = 4.0
      end)

      breach = conditions.enforce!

      expect(breach&.condition).to eq(:taker_rate)
    end
  end

  describe "abort: any order rejected, mis-sized, or duplicated" do
    it "halts when an order was rejected" do
      tape.add(clean_leg(number: 1, error: "order rejected: INSUFFICIENT_FUND"))

      breach = conditions.enforce!

      expect(breach.condition).to eq(:order_integrity)
      expect(breach.reason).to include("INSUFFICIENT_FUND")
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "halts when a fill came back for anything other than 1 contract" do
      tape.add(clean_leg(number: 1).tap { |l| l.entry.contracts = 2.0 })

      breach = conditions.enforce!

      expect(breach.condition).to eq(:order_integrity)
      expect(breach.reason).to include("mis-sized")
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "halts when the same exchange order id appears on two fills" do
      tape.add(clean_leg(number: 1))
      tape.add(clean_leg(number: 2).tap { |l| l.entry.order_id = "o1e" })

      breach = conditions.enforce!

      expect(breach.condition).to eq(:order_integrity)
      expect(breach.reason).to include("duplicate")
      expect(TradingHalt.risk_halted?).to be(true)
    end
  end

  describe "abort: a position outliving its intended hold by more than 2x" do
    it "halts when a leg was held past twice its intended hold" do
      tape.add(clean_leg(number: 1, intended_hold_seconds: 30, held_seconds: 61))

      breach = conditions.enforce!

      expect(breach.condition).to eq(:hold_overrun)
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "does not halt at exactly 2x" do
      tape.add(clean_leg(number: 1, intended_hold_seconds: 30, held_seconds: 60))

      expect(conditions.enforce!).to be_nil
    end
  end

  describe "abort: cumulative loss > $150" do
    it "halts once realized losses pass the authorized $150" do
      tape.add(clean_leg(number: 1, realized_pnl: -151.0))

      breach = conditions.enforce!

      expect(breach.condition).to eq(:cumulative_loss)
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "measures NET realized PnL, so a win offsets a loss" do
      tape.add(clean_leg(number: 1, realized_pnl: -140.0))
      tape.add(clean_leg(number: 2, realized_pnl: 20.0))

      expect(conditions.enforce!).to be_nil
    end
  end

  # #486 is explicit that this one does NOT abort — it kills the +22 bps maker
  # case, which is a finding, not an emergency.
  describe "maker fill rate below 30%" do
    it "does not halt, and is reported instead" do
      10.times do |i|
        filled = i.zero?
        tape.add(clean_leg(number: i + 1, intent: :maker,
          liquidity: filled ? "MAKER" : "TAKER").tap { |l| l.entry = nil unless filled })
      end

      expect(conditions.enforce!).to be_nil
      expect(TradingHalt.risk_halted?).to be(false)
      expect(tape.maker_fill_rate).to be < 0.30
    end
  end

  # A halt already recorded must not be overwritten: the first breach is the one
  # that explains the run.
  it "keeps the first breach's reason when a second condition also trips" do
    tape.add(clean_leg(number: 1, realized_pnl: -151.0).tap { |l| l.entry.contracts = 3.0 })

    conditions.enforce!
    first_reason = TradingHalt.status[:reason]

    described_class.new(tape: tape, logger: logger).enforce!

    expect(TradingHalt.status[:reason]).to eq(first_reason)
  end
end
